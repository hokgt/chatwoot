#!/usr/bin/env bash
#
# Fixture tests for deploy_check.sh. Fully offline: curl and sleep are mocked via
# DEPLOY_CHECK_CURL / DEPLOY_CHECK_SLEEP, so no network and no real waiting. The
# mock honors arbitrary extra args/headers (it scans for "-o <file>" and treats the
# last argument as the URL), so cache-busting query strings and no-cache headers do
# not break it. Both the root probe ("/?deploy_check=...") and the health probe
# ("/api?deploy_check=api-...") carry a cache-busting query; the mock classifies by
# matching "/api?" so the query does not hide the endpoint.
#
# MOCK_API_BODY lets a case inject an arbitrary raw /api body (e.g. invalid JSON).
# It is written only to the -o output file, never echoed to stdout or the curl log,
# so a malformed body cannot leak into assertions.
#
# Run: bash .github/scripts/deploy_check_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/deploy_check.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GOOD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
WRONG="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# Mock curl. Reads MOCK_* env to decide per-URL responses. Code "000" simulates a
# connection failure: it writes nothing (leaving the -o file untouched) and exits
# nonzero, exactly like curl on DNS/connect failure.
cat > "$WORK/curl" <<'MOCK'
#!/usr/bin/env bash
out=""; url=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  prev="$a"; url="$a"
done
printf '%s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
case "$url" in
  */api\?*) type=api ;;
  *r)       type=recheck ;;
  *)        type=root ;;
esac
case "$type" in
  root)    code="${MOCK_ROOT_CODE:-200}"; sha="${MOCK_ROOT_SHA:-}"; kind=root ;;
  recheck) code="${MOCK_RECHECK_CODE:-${MOCK_ROOT_CODE:-200}}"; sha="${MOCK_RECHECK_SHA:-${MOCK_ROOT_SHA:-}}"; kind=root ;;
  api)     code="${MOCK_API_CODE:-200}"; kind=api ;;
esac
[[ "$code" == "000" ]] && exit 1
if [[ -n "$out" ]]; then
  if [[ "$kind" == root ]]; then
    printf 'window.globalConfig = {"GIT_SHA":"%s","FOO":"bar"};\n' "$sha" > "$out"
  elif [[ -n "${MOCK_API_BODY+x}" ]]; then
    printf '%s' "$MOCK_API_BODY" > "$out"
  elif [[ "${MOCK_API_HEALTHY:-1}" == 1 ]]; then
    printf '{"version":"4.15.1","timestamp":"2026-01-01T00:00:00Z","queue_services":"ok","data_services":"ok"}\n' > "$out"
  else
    printf '{"version":"4.15.1","timestamp":"2026-01-01T00:00:00Z","queue_services":"ok","data_services":"failed"}\n' > "$out"
  fi
fi
printf '%s' "$code"
exit 0
MOCK
chmod +x "$WORK/curl"

pass=0; fail=0

# run_case <name> <expected_exit> — reads scenario from already-exported MOCK_*/env,
# runs the script with mocked curl+sleep, captures rc + combined output.
LOG=""; RC=0; OUT=""
run_case() {
  LOG="$WORK/log.$1"; : > "$LOG"
  OUT="$(MOCK_LOG="$LOG" \
        DEPLOY_CHECK_CURL="$WORK/curl" DEPLOY_CHECK_SLEEP=true \
        bash "$SCRIPT" 2>&1)"
  RC=$?
}

check() { # <desc> <condition-already-evaluated-as-rc>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "  ok: $1"
  else fail=$((fail+1)); echo "  FAIL: $1"; fi
}
expect_rc()  { [ "$RC" = "$1" ]; check "exit=$1 (got $RC)" $?; }
expect_out() { grep -qF "$1" <<<"$OUT"; check "output contains: $1" $?; }
expect_no_out() { ! grep -qF "$1" <<<"$OUT"; check "output lacks: $1" $?; }
expect_no_curl() { [ ! -s "$LOG" ]; check "no curl invoked" $?; }
expect_log()   { grep -qF "$1" "$LOG"; check "curl log contains: $1" $?; }
expect_no_log(){ ! grep -qF "$1" "$LOG"; check "curl log lacks: $1" $?; }
# Assert some single curl invocation carried BOTH substrings (same request line).
expect_log_line() { grep -F "$1" "$LOG" | grep -qF "$2"; check "curl log line has '$1' + '$2'" $?; }

base_env() {
  export DEPLOY_CHECK_BASE_URL="https://dev.example"
  export DEPLOY_CHECK_EXPECTED_SHA="$GOOD"
  export DEPLOY_CHECK_MAX_ATTEMPTS=2
  export DEPLOY_CHECK_INTERVAL=0
  export DEPLOY_CHECK_CONNECT_TIMEOUT=5
  export DEPLOY_CHECK_MAX_TIME=5
  unset MOCK_ROOT_CODE MOCK_ROOT_SHA MOCK_API_CODE MOCK_API_HEALTHY MOCK_API_BODY \
        MOCK_RECHECK_CODE MOCK_RECHECK_SHA
}

echo "== 1. wrong-SHA but healthy /api -> FAIL (never reaches /api) =="
base_env; export MOCK_ROOT_SHA="$WRONG"
run_case wrong_sha
expect_rc 1
expect_out "GIT_SHA mismatch"
expect_no_log "/api"

echo "== 2. expected-SHA, healthy, stable recheck -> PASS (+ cache-busting proof) =="
base_env; export MOCK_ROOT_SHA="$GOOD"
run_case pass
expect_rc 0
expect_out "Deploy Check PASSED"
expect_log "deploy_check=${GOOD}-a1"                  # cache-busting query on initial root probe
expect_log "deploy_check=${GOOD}-a1r"                 # distinct marker on recheck probe
expect_log "/api?deploy_check=api-${GOOD}-a1"         # cache-busting query on /api health probe
expect_log "Cache-Control: no-cache"                  # revalidation header sent
expect_log_line "/api?deploy_check=api-${GOOD}-a1" "Cache-Control: no-cache"  # /api sends no-cache
expect_log_line "/api?deploy_check=api-${GOOD}-a1" "Pragma: no-cache"         # /api sends Pragma no-cache

echo "== 3a. SHA changes during health validation (200, different SHA) -> FAIL =="
base_env; export DEPLOY_CHECK_MAX_ATTEMPTS=1
export MOCK_ROOT_SHA="$GOOD" MOCK_RECHECK_CODE=200 MOCK_RECHECK_SHA="$WRONG"
run_case race_changed
expect_rc 1
expect_out "SHA changed during health validation"

echo "== 3b. recheck HTTP!=200 must not report the stale 200 body as current SHA =="
base_env; export DEPLOY_CHECK_MAX_ATTEMPTS=1
# initial root serves GOOD (writes it to the shared body file); recheck drops the
# connection (000) and writes nothing, so the file still holds GOOD. The fix must
# report SHA=none and NOT pass.
export MOCK_ROOT_SHA="$GOOD" MOCK_RECHECK_CODE=000
run_case race_stale
expect_rc 1
expect_out "recheck HTTP 000, SHA none"
expect_no_out "PASSED"

echo "== 4. malformed tunables / URL fail clearly, before any network call =="
base_env; export DEPLOY_CHECK_MAX_ATTEMPTS=abc
run_case bad_attempts
expect_rc 1; expect_out "DEPLOY_CHECK_MAX_ATTEMPTS must be a positive integer"; expect_no_curl

base_env; export DEPLOY_CHECK_MAX_ATTEMPTS=0
run_case zero_attempts
expect_rc 1; expect_out "DEPLOY_CHECK_MAX_ATTEMPTS must be a positive integer"; expect_no_curl

base_env; export DEPLOY_CHECK_INTERVAL=-1
run_case neg_interval
expect_rc 1; expect_out "DEPLOY_CHECK_INTERVAL must be a nonnegative number"; expect_no_curl

base_env; export DEPLOY_CHECK_CONNECT_TIMEOUT=0
run_case zero_connect
expect_rc 1; expect_out "DEPLOY_CHECK_CONNECT_TIMEOUT must be a positive integer"; expect_no_curl

base_env; export DEPLOY_CHECK_BASE_URL="https://user@dev.example"
run_case url_userinfo
expect_rc 1; expect_out "must not contain userinfo"; expect_no_curl

base_env; export DEPLOY_CHECK_BASE_URL="https://dev.example?x=1"
run_case url_query
expect_rc 1; expect_out "must not contain a query string"; expect_no_curl

base_env; export DEPLOY_CHECK_BASE_URL="https://"
run_case url_no_host
expect_rc 1; expect_out "must include a host"; expect_no_curl

base_env; export DEPLOY_CHECK_BASE_URL=""
run_case url_blank
expect_rc 1; expect_out "DEPLOY_CHECK_BASE_URL is not set"; expect_no_curl

base_env; export DEPLOY_CHECK_EXPECTED_SHA="not-a-sha"
run_case bad_sha
expect_rc 1; expect_out "DEPLOY_CHECK_EXPECTED_SHA must be a 40-hex commit SHA"; expect_no_curl

echo "== 4b. fractional interval is accepted (nonnegative numeric) =="
base_env; export DEPLOY_CHECK_INTERVAL=1.5 MOCK_ROOT_SHA="$GOOD"
run_case frac_interval
expect_rc 0; expect_out "Deploy Check PASSED"

echo "== 4c. matching SHA but /api unhealthy JSON -> FAIL =="
base_env; export DEPLOY_CHECK_MAX_ATTEMPTS=1 MOCK_ROOT_SHA="$GOOD" MOCK_API_HEALTHY=0
run_case api_unhealthy
expect_rc 1
expect_out "/api: unhealthy (data_services_not_ok)"
expect_no_out "PASSED"
expect_log "/api?deploy_check=api-${GOOD}-a1"

echo "== 4d. matching SHA but /api invalid JSON -> FAIL (raw body not leaked) =="
base_env; export DEPLOY_CHECK_MAX_ATTEMPTS=1 MOCK_ROOT_SHA="$GOOD" MOCK_API_BODY="<html>not json SECRETLEAK</html>"
run_case api_invalid_json
expect_rc 1
expect_out "/api: unhealthy (invalid_json)"
expect_no_out "SECRETLEAK"       # raw body must never surface in output
expect_no_log "SECRETLEAK"       # nor in the curl request log

echo "== 4e. matching SHA but /api HTTP != 200 -> FAIL =="
base_env; export DEPLOY_CHECK_MAX_ATTEMPTS=1 MOCK_ROOT_SHA="$GOOD" MOCK_API_CODE=503
run_case api_non_200
expect_rc 1
expect_out "/api: HTTP 503 (want 200)"
expect_no_out "PASSED"

echo "== 4f. root HTTP 200 but no GIT_SHA in window.globalConfig -> FAIL (no /api) =="
base_env; export DEPLOY_CHECK_MAX_ATTEMPTS=1 MOCK_ROOT_SHA=""
run_case root_no_sha
expect_rc 1
expect_out "no GIT_SHA in window.globalConfig"
expect_no_out "PASSED"
expect_no_log "/api?"             # never advances to the health probe

echo "== 5. unavailable target -> bounded FAIL after MAX_ATTEMPTS =="
base_env; export DEPLOY_CHECK_MAX_ATTEMPTS=3 MOCK_ROOT_CODE=000
run_case unavailable
expect_rc 1
expect_out "not confirmed after 3 attempts"
expect_out "Attempt 3/3"
[ "$(grep -c '.' "$LOG")" -eq 3 ]; check "exactly 3 root probes made" $?

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
