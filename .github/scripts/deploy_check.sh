#!/usr/bin/env bash
#
# Deploy Check — validate that the self-hosted Development target is running the
# EXACT commit under review, and is healthy.
#
# OPERATOR CONTRACT: this script NEVER deploys. The shared self-hosted
# Development target is deployed out-of-band (manually) by the operator. This
# script only polls the externally deployed candidate and validates it. It is a
# read-only attestation gate, deliberately built so it CANNOT pass against a
# healthy target that is running a different SHA.
#
# How it passes:
#   1. GET <base>/          -> HTTP 200, window.globalConfig advertises
#                              "GIT_SHA":"<expected>" (exact 40-hex match).
#   2. GET <base>/api       -> HTTP 200, valid JSON with a nonempty "version",
#                              nonempty "timestamp", queue_services == "ok",
#                              data_services == "ok".
#   3. GET <base>/ again    -> still the expected GIT_SHA (guards against an
#                              overwrite/redeploy race during health checks).
#   Only when all three hold does it exit 0.
#
# Every probe — root SHA and /api health — is cache-busted: a deterministic query
# string carrying the expected SHA plus an attempt/recheck marker gives each probe a
# distinct URL, and every GET sends Cache-Control/Pragma no-cache. This stops a stale
# intermediary, browser, or CDN cache from advertising the expected SHA at the root
# while /api is served by a different, current deployment, or from replaying a stale
# healthy /api body that masks a current dependency failure (a false pass either way).
#
# Inputs (env):
#   DEPLOY_CHECK_BASE_URL       required, self-hosted https base URL (no default)
#   DEPLOY_CHECK_EXPECTED_SHA   required, 40-hex commit SHA to require
#
# Tunables (env, safe CI defaults; also used to make fixture tests fast):
#   DEPLOY_CHECK_MAX_ATTEMPTS    default 20
#   DEPLOY_CHECK_INTERVAL        seconds between attempts, default 30
#   DEPLOY_CHECK_CONNECT_TIMEOUT curl connect timeout secs, default 10
#   DEPLOY_CHECK_MAX_TIME        curl overall timeout secs, default 30
#   DEPLOY_CHECK_CURL            curl binary (overridable for fixture tests)
#   DEPLOY_CHECK_SLEEP           sleep binary (overridable for fixture tests)
#
# 20 attempts * 30s == a ~10 minute bounded validation window for a manually
# deployed shared target, without any fixed up-front delay: the very first
# attempt can pass the moment the operator's deploy is live.
#
# Never prints response bodies or secrets. The base URL is a non-secret
# repository variable.
set -euo pipefail

fail() { echo "Deploy Check FAILED: $*" >&2; exit 1; }

BASE_URL="${DEPLOY_CHECK_BASE_URL:-}"
EXPECTED_SHA="${DEPLOY_CHECK_EXPECTED_SHA:-}"
MAX_ATTEMPTS="${DEPLOY_CHECK_MAX_ATTEMPTS:-20}"
INTERVAL="${DEPLOY_CHECK_INTERVAL:-30}"
CONNECT_TIMEOUT="${DEPLOY_CHECK_CONNECT_TIMEOUT:-10}"
MAX_TIME="${DEPLOY_CHECK_MAX_TIME:-30}"
CURL="${DEPLOY_CHECK_CURL:-curl}"
SLEEP="${DEPLOY_CHECK_SLEEP:-sleep}"

[[ -n "$BASE_URL" ]] || fail "DEPLOY_CHECK_BASE_URL is not set (configure the repository variable vars.DEPLOY_CHECK_BASE_URL)."
[[ "$BASE_URL" == https://* ]] || fail "DEPLOY_CHECK_BASE_URL must be an https:// URL."
[[ -n "$EXPECTED_SHA" ]] || fail "DEPLOY_CHECK_EXPECTED_SHA is not set."
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "DEPLOY_CHECK_EXPECTED_SHA must be a 40-hex commit SHA (got a non-matching value)."

# URL validation. The base is a trusted, non-secret repository variable, but reject
# obvious malformed forms so the URLs we build stay deterministic and single-origin:
# no whitespace/control chars, no userinfo, no query, no fragment.
[[ "$BASE_URL" != *[[:space:]]* ]] || fail "DEPLOY_CHECK_BASE_URL must not contain whitespace."
[[ "$BASE_URL" != *"@"* ]]         || fail "DEPLOY_CHECK_BASE_URL must not contain userinfo ('@')."
[[ "$BASE_URL" != *"?"* ]]         || fail "DEPLOY_CHECK_BASE_URL must not contain a query string ('?')."
[[ "$BASE_URL" != *"#"* ]]         || fail "DEPLOY_CHECK_BASE_URL must not contain a fragment ('#')."

# Require a nonempty host BEFORE any normalization so a bare scheme cannot slip
# through, then normalize trailing slashes so "<base>/" and "<base>/api" are
# well-formed. Order matters: checking the host first stops the slash-strip from
# eating the scheme's "//" and leaving a non-empty-but-hostless base.
[[ -n "${BASE_URL#https://}" && "${BASE_URL#https://}" != /* ]] || fail "DEPLOY_CHECK_BASE_URL must include a host (e.g. https://host.example)."
while [[ "$BASE_URL" == */ ]]; do BASE_URL="${BASE_URL%/}"; done

# Validate tunables before the loop so a malformed value fails clearly and
# deterministically instead of causing arithmetic/sleep/curl surprises mid-run.
[[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]    || fail "DEPLOY_CHECK_MAX_ATTEMPTS must be a positive integer (got '$MAX_ATTEMPTS')."
[[ "$CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail "DEPLOY_CHECK_CONNECT_TIMEOUT must be a positive integer (got '$CONNECT_TIMEOUT')."
[[ "$MAX_TIME" =~ ^[1-9][0-9]*$ ]]        || fail "DEPLOY_CHECK_MAX_TIME must be a positive integer (got '$MAX_TIME')."
[[ "$INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]]  || fail "DEPLOY_CHECK_INTERVAL must be a nonnegative number (got '$INTERVAL')."

# GET a URL into an output file; echoes only the 3-digit HTTP status. Any curl
# failure (DNS, connect, timeout) collapses to "000". Never emits the body. Sends
# no-cache request headers so intermediaries revalidate rather than serve a stale
# body.
http_get() {
  local url="$1" out="$2" code
  code=$("$CURL" -sS -o "$out" -w '%{http_code}' \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    "$url" 2>/dev/null) || code="000"
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  printf '%s' "$code"
}

# Extract the 40-hex GIT_SHA from window.globalConfig without printing the HTML.
# Prints the SHA, or nothing if absent.
extract_git_sha() {
  grep -oE '"GIT_SHA":"[0-9a-f]{40}"' "$1" 2>/dev/null | head -n1 | grep -oE '[0-9a-f]{40}' || true
}

# Validate the /api JSON. Prints a single reason token ("ok" on success); never
# prints the body. Returns nonzero on any failure.
check_health() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("invalid_json"); sys.exit(1)
if not isinstance(d, dict):
    print("not_an_object"); sys.exit(1)
if not d.get("version"):
    print("empty_version"); sys.exit(1)
if not d.get("timestamp"):
    print("empty_timestamp"); sys.exit(1)
if d.get("queue_services") != "ok":
    print("queue_services_not_ok"); sys.exit(1)
if d.get("data_services") != "ok":
    print("data_services_not_ok"); sys.exit(1)
print("ok")
PY
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root_body="$tmp/root.html"
api_body="$tmp/api.json"

echo "Deploy Check: validating $BASE_URL is running $EXPECTED_SHA (up to $MAX_ATTEMPTS attempts, ${INTERVAL}s apart). This job never deploys."

attempt=1
last_root_code="none"
last_root_sha="none"
last_health="n/a"

while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  echo "Attempt $attempt/$MAX_ATTEMPTS"

  # Cache-busting query: deterministic (expected SHA + attempt marker), distinct per
  # attempt, so a cached root response cannot masquerade as a fresh probe.
  root_url="$BASE_URL/?deploy_check=${EXPECTED_SHA}-a${attempt}"
  root_code=$(http_get "$root_url" "$root_body")
  last_root_code="$root_code"

  if [ "$root_code" != "200" ]; then
    echo "  root: HTTP $root_code (want 200)"
  else
    root_sha=$(extract_git_sha "$root_body")
    last_root_sha="${root_sha:-none}"
    if [ -z "$root_sha" ]; then
      echo "  root: HTTP 200 but no GIT_SHA in window.globalConfig"
    elif [ "$root_sha" != "$EXPECTED_SHA" ]; then
      echo "  root: GIT_SHA mismatch (want $EXPECTED_SHA, got $root_sha)"
    else
      echo "  root: GIT_SHA matches expected"
      # Cache-bust /api the same way as the root probe (expected SHA + attempt
      # marker) so a stale healthy /api body cannot mask a current dependency
      # failure. Distinct 'api' prefix keeps it a different URL from the root.
      api_url="$BASE_URL/api?deploy_check=api-${EXPECTED_SHA}-a${attempt}"
      api_code=$(http_get "$api_url" "$api_body")
      if [ "$api_code" != "200" ]; then
        last_health="api_http_$api_code"
        echo "  /api: HTTP $api_code (want 200)"
      else
        reason=$(check_health "$api_body") || true
        last_health="${reason:-invalid_json}"
        if [ "$last_health" != "ok" ]; then
          echo "  /api: unhealthy ($last_health)"
        else
          echo "  /api: healthy"
          # Re-confirm the root SHA after health checks so an overwrite/redeploy
          # that lands mid-validation cannot slip through as a pass. Distinct
          # cache-busting marker ('r') so the recheck can't reuse a cached probe.
          recheck_url="$BASE_URL/?deploy_check=${EXPECTED_SHA}-a${attempt}r"
          recheck_code=$(http_get "$recheck_url" "$root_body")
          # Only trust the body as the current SHA on HTTP 200; on any other status
          # the file may hold a stale (earlier-200) body, which must not be reported
          # or compared as the current SHA.
          if [ "$recheck_code" = "200" ]; then
            recheck_sha=$(extract_git_sha "$root_body")
          else
            recheck_sha=""
          fi
          last_root_code="$recheck_code"
          last_root_sha="${recheck_sha:-none}"
          if [ "$recheck_code" = "200" ] && [ "$recheck_sha" = "$EXPECTED_SHA" ]; then
            echo "Deploy Check PASSED: $BASE_URL is running $EXPECTED_SHA and healthy."
            exit 0
          fi
          echo "  root: SHA changed during health validation (recheck HTTP $recheck_code, SHA ${recheck_sha:-none})"
        fi
      fi
    fi
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    "$SLEEP" "$INTERVAL"
  fi
  attempt=$((attempt + 1))
done

fail "expected SHA $EXPECTED_SHA not confirmed after $MAX_ATTEMPTS attempts (last root HTTP=$last_root_code, last root SHA=$last_root_sha, last health=$last_health)."
