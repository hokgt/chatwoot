#!/usr/bin/env bash
# =============================================================================
# Deployment-contract regression suite (no Docker daemon, no mutation).
#
# Proves the canonical entrypoint's preflight + the domain-boundary monitor behave
# correctly using a FAKE `docker` executable and fixture compose-config JSON. In
# particular it proves — with a deliberate negative case — that when the mandatory
# catalog contract is not satisfied, the entrypoint fails BEFORE any `docker compose
# up` is invoked (the fake records an "up" marker that must never appear), and that a
# valid contract passes preflight WITHOUT recreating any container. No secret contents
# are ever needed.
# =============================================================================
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$TESTS_DIR" rev-parse --show-toplevel 2>/dev/null || ( cd "$TESTS_DIR/../../../.." && pwd ))"
DEPLOY_SH="$REPO_ROOT/custom/wijaya/deploy/deploy.sh"
MONITOR_SH="$REPO_ROOT/custom/wijaya/scripts/marine_domain_boundary_monitor.sh"
CONTRACT_SH="$REPO_ROOT/custom/wijaya/scripts/check_deploy_contract.sh"
BASE_COMPOSE="$REPO_ROOT/docker-compose.deploy.yaml"
CATALOG_OVERLAY="$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-catalog.yml"
SOP_OVERLAY="$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-sop-worker.yml"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()   { printf '  ok   - %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL - %s\n' "$1"; fail=$((fail+1)); }

# --- Fake docker ------------------------------------------------------------
# Handles `compose version`, `compose ... config --format json` (prints the JSON
# named by FAKE_CONFIG_JSON_FILE, or empty when FAKE_CONFIG_EMPTY=1), and records an
# `up`/`image inspect` invocation by touching a marker so tests can assert they were
# never reached.
FAKE_DOCKER="$WORK/docker"
cat >"$FAKE_DOCKER" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "compose" ]]; then
  shift
  # find the trailing subcommand (skip -f <file> pairs)
  args=("$@")
  sub=""
  i=0
  while [[ $i -lt ${#args[@]} ]]; do
    a="${args[$i]}"
    case "$a" in
      -f) i=$((i+2)); continue ;;
      version|config|up|ps|logs|exec) sub="$a"; break ;;
      *) i=$((i+1)); continue ;;
    esac
  done
  case "$sub" in
    version) echo "Docker Compose version vFAKE"; exit 0 ;;
    config)
      if [[ "${FAKE_CONFIG_EMPTY:-0}" == "1" ]]; then exit 0; fi
      cat "${FAKE_CONFIG_JSON_FILE:?}"; exit 0 ;;
    up)      : "${FAKE_UP_MARKER:?}"; echo "up" >>"$FAKE_UP_MARKER"; exit 0 ;;
    *) exit 0 ;;
  esac
elif [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  : "${FAKE_IMAGE_MARKER:?}"; echo "inspect" >>"$FAKE_IMAGE_MARKER"; exit 0
fi
exit 0
FAKE
chmod +x "$FAKE_DOCKER"

# --- Secret fixtures --------------------------------------------------------
SECRET_OK="$WORK/secret_ok"
SECRET_EMPTY="$WORK/secret_empty"
printf 'not-a-real-password\n' >"$SECRET_OK"   # non-empty; content is irrelevant
: >"$SECRET_EMPTY"                              # deliberately empty

# Build a compose-config JSON fixture. Args: <out> <read_only:true|false> <secret_path> [omit_catalog:1]
make_config() {
  local out="$1" ro="$2" secret="$3" omit="${4:-0}"
  if [[ "$omit" == "1" ]]; then
    cat >"$out" <<JSON
{ "services": {
    "rails":   { "image": "hokgt-chatwoot:test", "environment": {}, "volumes": [] },
    "sidekiq": { "image": "hokgt-chatwoot:test", "environment": {}, "volumes": [] }
} }
JSON
    return
  fi
  cat >"$out" <<JSON
{ "services": {
    "rails": {
      "image": "hokgt-chatwoot:test",
      "environment": { "MARINE_CATALOG_PG_PASSWORD_FILE": "/run/secrets/marine_catalog_pg_password" },
      "volumes": [ { "type": "bind", "source": "$secret", "target": "/run/secrets/marine_catalog_pg_password", "read_only": $ro } ]
    },
    "sidekiq": {
      "image": "hokgt-chatwoot:test",
      "environment": { "MARINE_CATALOG_PG_PASSWORD_FILE": "/run/secrets/marine_catalog_pg_password" },
      "volumes": [ { "type": "bind", "source": "$secret", "target": "/run/secrets/marine_catalog_pg_password", "read_only": $ro } ]
    }
} }
JSON
}

# Invoke deploy.sh with the fake docker + a given config fixture. Runs in the CURRENT
# shell (not a subshell) so the globals RC / UP_MARKER / IMAGE_MARKER are visible to
# the caller for assertions.
CALLN=0
run_deploy() {
  local mode="$1" cfg="$2"; shift 2
  local extra_env=("$@")
  CALLN=$((CALLN+1))
  UP_MARKER="$WORK/up.$CALLN"; IMAGE_MARKER="$WORK/img.$CALLN"
  rm -f "$UP_MARKER" "$IMAGE_MARKER"
  RC=0
  env \
    DOCKER="$FAKE_DOCKER" \
    MARINE_DEPLOY_BASE_COMPOSE="$BASE_COMPOSE" \
    MARINE_DEPLOY_CATALOG_OVERLAY="$CATALOG_OVERLAY" \
    MARINE_DEPLOY_SOP_OVERLAY="$SOP_OVERLAY" \
    FAKE_CONFIG_JSON_FILE="$cfg" \
    FAKE_UP_MARKER="$UP_MARKER" \
    FAKE_IMAGE_MARKER="$IMAGE_MARKER" \
    "${extra_env[@]}" \
    bash "$DEPLOY_SH" "$mode" >"$WORK/out.log" 2>&1 || RC=$?
}

echo "== deploy.sh preflight =="

# 1) POSITIVE: valid contract, --check → passes preflight, NO recreation.
CFG_OK="$WORK/cfg_ok.json"; make_config "$CFG_OK" true "$SECRET_OK"
run_deploy --check "$CFG_OK"; rc=$RC
if [[ "$rc" == "0" && ! -f "$UP_MARKER" ]]; then
  ok "valid contract passes --check without recreating containers"
else
  bad "valid --check (rc=$rc, up_marker=$([[ -f "$UP_MARKER" ]] && echo yes || echo no))"; cat "$WORK/out.log"
fi

# 2) NEGATIVE (the key proof): catalog contract absent, --deploy → fails BEFORE `up`.
CFG_OMIT="$WORK/cfg_omit.json"; make_config "$CFG_OMIT" true "$SECRET_OK" 1
run_deploy --deploy "$CFG_OMIT"; rc=$RC
if [[ "$rc" != "0" && ! -f "$UP_MARKER" && ! -f "$IMAGE_MARKER" ]]; then
  ok "missing catalog contract fails --deploy BEFORE any docker compose up (no up marker, no image inspect)"
else
  bad "negative --deploy (rc=$rc, up=$([[ -f "$UP_MARKER" ]] && echo yes || echo no), img=$([[ -f "$IMAGE_MARKER" ]] && echo yes || echo no))"; cat "$WORK/out.log"
fi
grep -q "missing MARINE_CATALOG_PG_PASSWORD_FILE" "$WORK/out.log" \
  && ok "negative case reports the missing catalog env" \
  || bad "negative case missing-env message"

# 2b) NEGATIVE (explicit omission simulation): a compose overlay file PHYSICALLY EXISTS on
#     disk but omits the mandatory catalog contract. This mirrors the real 2026-09 incident
#     (a present-but-wrong override). Preflight MUST reject it on the missing contract and
#     exit BEFORE any image inspect or `docker compose up` — no image marker, no up marker.
DUMMY_OVERLAY="$WORK/dummy_overlay.yml"
cat >"$DUMMY_OVERLAY" <<'YML'
services:
  rails:
    image: hokgt-chatwoot:test
  sidekiq:
    image: hokgt-chatwoot:test
YML
run_deploy --deploy "$CFG_OMIT" MARINE_DEPLOY_CATALOG_OVERLAY="$DUMMY_OVERLAY"; rc=$RC
if [[ "$rc" != "0" && ! -f "$UP_MARKER" && ! -f "$IMAGE_MARKER" ]]; then
  ok "present overlay lacking the catalog contract fails preflight BEFORE image inspect/up"
else
  bad "dummy-overlay omission case (rc=$rc, up=$([[ -f "$UP_MARKER" ]] && echo yes || echo no), img=$([[ -f "$IMAGE_MARKER" ]] && echo yes || echo no))"; cat "$WORK/out.log"
fi
grep -q "missing MARINE_CATALOG_PG_PASSWORD_FILE" "$WORK/out.log" \
  && ok "dummy-overlay case reports the missing catalog env contract" \
  || bad "dummy-overlay missing-env message"

# 3) NEGATIVE: mount present but NOT read-only → fails, no up.
CFG_RW="$WORK/cfg_rw.json"; make_config "$CFG_RW" false "$SECRET_OK"
run_deploy --deploy "$CFG_RW"; rc=$RC
[[ "$rc" != "0" && ! -f "$UP_MARKER" ]] \
  && ok "non-read-only catalog mount fails before up" \
  || { bad "non-read-only case (rc=$rc)"; cat "$WORK/out.log"; }
grep -q "not read-only" "$WORK/out.log" && ok "reports not-read-only" || bad "not-read-only message"

# 4) NEGATIVE: host secret file empty → fails, no up (no secret CONTENT needed).
CFG_EMPTY="$WORK/cfg_empty.json"; make_config "$CFG_EMPTY" true "$SECRET_EMPTY"
run_deploy --deploy "$CFG_EMPTY"; rc=$RC
[[ "$rc" != "0" && ! -f "$UP_MARKER" ]] \
  && ok "empty host secret file fails before up" \
  || { bad "empty-secret case (rc=$rc)"; cat "$WORK/out.log"; }
grep -q "empty" "$WORK/out.log" && ok "reports empty secret file" || bad "empty-secret message"

# 5) NEGATIVE: invalid/empty resolved config → fails, no up.
run_deploy --deploy "$CFG_OK" FAKE_CONFIG_EMPTY=1; rc=$RC
[[ "$rc" != "0" && ! -f "$UP_MARKER" ]] \
  && ok "empty compose config fails before up" \
  || { bad "empty-config case (rc=$rc)"; cat "$WORK/out.log"; }

# 6) NEGATIVE: mandatory catalog overlay missing on disk → fails fast (docker never called).
UP_MARKER="$WORK/up.disk"; IMAGE_MARKER="$WORK/img.disk"; rm -f "$UP_MARKER" "$IMAGE_MARKER"
rc=0
env DOCKER="$FAKE_DOCKER" \
    MARINE_DEPLOY_BASE_COMPOSE="$BASE_COMPOSE" \
    MARINE_DEPLOY_CATALOG_OVERLAY="$WORK/does-not-exist.yml" \
    MARINE_DEPLOY_SOP_OVERLAY="$SOP_OVERLAY" \
    FAKE_CONFIG_JSON_FILE="$CFG_OK" FAKE_UP_MARKER="$UP_MARKER" FAKE_IMAGE_MARKER="$IMAGE_MARKER" \
    bash "$DEPLOY_SH" --deploy >"$WORK/out.log" 2>&1 || rc=$?
[[ "$rc" != "0" && ! -f "$UP_MARKER" ]] \
  && ok "missing catalog overlay on disk fails before up" \
  || { bad "missing-overlay-on-disk case (rc=$rc)"; cat "$WORK/out.log"; }

# 7) Unsupported option and service are rejected.
rc=0; env DOCKER="$FAKE_DOCKER" bash "$DEPLOY_SH" --check --frobnicate >"$WORK/out.log" 2>&1 || rc=$?
[[ "$rc" != "0" ]] && grep -q "unsupported option" "$WORK/out.log" \
  && ok "rejects unsupported option" || bad "unsupported option not rejected"
rc=0; env DOCKER="$FAKE_DOCKER" bash "$DEPLOY_SH" --check --service postgres >"$WORK/out.log" 2>&1 || rc=$?
[[ "$rc" != "0" ]] && grep -q "unsupported service" "$WORK/out.log" \
  && ok "rejects unsupported service (postgres)" || bad "unsupported service not rejected"

echo "== deploy.sh sentinel parsers (unit) =="

# The pure parsers are sourced (MARINE_DEPLOY_SOURCE_ONLY=1) so we can feed them raw text
# WITHOUT a live docker daemon. This proves the catalog-gate sentinel survives Rails boot
# noise on stdout, and that the probe verdict enforces healthy categories + zero persistence.

# 8) catalog-gate sentinel: PASS/FAIL extracted from an exact anchored line; boot noise ignored.
( export MARINE_DEPLOY_SOURCE_ONLY=1
  source "$DEPLOY_SH" --check >/dev/null 2>&1
  [[ "$(parse_catalog_gate_verdict "$(printf 'I, [boot] rails booting\nDEPRECATION WARNING: x\nMARINE_CATALOG_GATE:PASS\n')")" == PASS ]] || exit 11
  [[ "$(parse_catalog_gate_verdict "$(printf 'noise\nMARINE_CATALOG_GATE:FAIL:Marine::Catalog::Errors::CatalogUnavailableError\n')")" == FAIL ]] || exit 12
  [[ -z "$(parse_catalog_gate_verdict 'only boot noise, no sentinel line at all')" ]] || exit 13
) && ok "catalog-gate sentinel parses PASS/FAIL from an exact line and ignores boot noise" \
  || bad "catalog-gate sentinel parse (exit $?)"

# 9) probe sentinel: OK only when categories healthy AND all persistence deltas are zero AND
#    the ROLLBACK=1 marker is present (proving the probe ran in a rolled-back transaction).
( export MARINE_DEPLOY_SOURCE_ONLY=1
  source "$DEPLOY_SH" --check >/dev/null 2>&1
  [[ "$(evaluate_probe_sentinel "$(printf 'boot noise line\nMARINE_PROBE:GREET=allow UNREL=unrelated DCONV=0 DMSG=0 DRESP=0 ROLLBACK=1\n')")" == OK ]] || exit 21
  [[ "$(evaluate_probe_sentinel 'MARINE_PROBE:GREET=error UNREL=unrelated DCONV=0 DMSG=0 DRESP=0 ROLLBACK=1')" == greet-error ]] || exit 22
  [[ "$(evaluate_probe_sentinel 'MARINE_PROBE:GREET=allow UNREL=extraction DCONV=0 DMSG=0 DRESP=0 ROLLBACK=1')" == unrel-not-denied ]] || exit 23
  [[ "$(evaluate_probe_sentinel 'MARINE_PROBE:GREET=allow UNREL=unrelated DCONV=0 DMSG=1 DRESP=0 ROLLBACK=1')" == persisted ]] || exit 24
  [[ "$(evaluate_probe_sentinel 'no sentinel at all')" == no-sentinel ]] || exit 25
  # Missing rollback marker → not OK even when categories are healthy and deltas are zero.
  [[ "$(evaluate_probe_sentinel 'MARINE_PROBE:GREET=allow UNREL=unrelated DCONV=0 DMSG=0 DRESP=0')" == no-rollback ]] || exit 26
) && ok "probe sentinel enforces healthy categories + zero deltas + rollback marker" \
  || bad "probe sentinel parse (exit $?)"

# 10) public-HTTP readiness retry: injectable curl/sleep, bounded attempts. Fake sleep is a
#     no-op (records invocations) so the retry loop is proven WITHOUT any real delay.
cat >"$WORK/nosleep" <<'C'
#!/usr/bin/env bash
[[ -n "${SLEEP_COUNT_FILE:-}" ]] && echo x >>"$SLEEP_COUNT_FILE"
exit 0
C
cat >"$WORK/curl_flaky" <<'C'
#!/usr/bin/env bash
n=$(( $(cat "$FLAKY_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FLAKY_COUNT_FILE"
if [[ "$n" -ge 3 ]]; then printf '200'; exit 0; else printf '000'; exit 1; fi
C
cat >"$WORK/curl_dead" <<'C'
#!/usr/bin/env bash
printf '000'; exit 1
C
chmod +x "$WORK/nosleep" "$WORK/curl_flaky" "$WORK/curl_dead"

: >"$WORK/flaky.count"; : >"$WORK/sleep.count"
( export MARINE_DEPLOY_SOURCE_ONLY=1 MARINE_CURL="$WORK/curl_flaky" MARINE_SLEEP="$WORK/nosleep" \
         MARINE_PUBLIC_HTTP_MAX_ATTEMPTS=5 MARINE_PUBLIC_HTTP_SLEEP_SECONDS=0 \
         FLAKY_COUNT_FILE="$WORK/flaky.count" SLEEP_COUNT_FILE="$WORK/sleep.count"
  source "$DEPLOY_SH" --check >/dev/null 2>&1
  gate_public_http >/dev/null 2>&1
) && ok "gate_public_http retries and passes once HTTP 200 appears (3rd attempt)" \
  || bad "gate_public_http retry-then-pass"
# It slept exactly twice before the 3rd (successful) attempt — proving a bounded retry.
[[ "$(wc -l <"$WORK/sleep.count" | tr -d ' ')" == "2" ]] \
  && ok "gate_public_http slept a bounded number of times before success" \
  || bad "gate_public_http sleep count ($(wc -l <"$WORK/sleep.count" | tr -d ' '))"

: >"$WORK/sleep.count"
rc=0
( export MARINE_DEPLOY_SOURCE_ONLY=1 MARINE_CURL="$WORK/curl_dead" MARINE_SLEEP="$WORK/nosleep" \
         MARINE_PUBLIC_HTTP_MAX_ATTEMPTS=3 MARINE_PUBLIC_HTTP_SLEEP_SECONDS=0 \
         SLEEP_COUNT_FILE="$WORK/sleep.count"
  source "$DEPLOY_SH" --check >/dev/null 2>&1
  gate_public_http >/dev/null 2>&1
) || rc=$?
[[ "$rc" != "0" ]] \
  && ok "gate_public_http fails explicitly after the bounded attempt budget is exhausted" \
  || bad "gate_public_http exhausted-budget case (rc=$rc)"

echo "== deploy.sh readiness-tunable validation (unit) =="

# 12) Malformed readiness tunables must fail safely at load with an explicit message; valid
#     (including fractional/zero) values pass. Sourced with MARINE_DEPLOY_SOURCE_ONLY=1.
rc=0; ( export MARINE_DEPLOY_SOURCE_ONLY=1 MARINE_PUBLIC_HTTP_MAX_ATTEMPTS=0
        source "$DEPLOY_SH" --check >"$WORK/tun.log" 2>&1 ) || rc=$?
[[ "$rc" != "0" ]] && grep -q "MARINE_PUBLIC_HTTP_MAX_ATTEMPTS must be a positive integer" "$WORK/tun.log" \
  && ok "rejects MARINE_PUBLIC_HTTP_MAX_ATTEMPTS=0 (non-positive)" || { bad "max-attempts=0 not rejected"; cat "$WORK/tun.log"; }

rc=0; ( export MARINE_DEPLOY_SOURCE_ONLY=1 MARINE_PUBLIC_HTTP_MAX_ATTEMPTS=abc
        source "$DEPLOY_SH" --check >"$WORK/tun.log" 2>&1 ) || rc=$?
[[ "$rc" != "0" ]] && ok "rejects non-integer MARINE_PUBLIC_HTTP_MAX_ATTEMPTS" || { bad "non-integer max-attempts not rejected"; cat "$WORK/tun.log"; }

rc=0; ( export MARINE_DEPLOY_SOURCE_ONLY=1 MARINE_PUBLIC_HTTP_SLEEP_SECONDS=-1
        source "$DEPLOY_SH" --check >"$WORK/tun.log" 2>&1 ) || rc=$?
[[ "$rc" != "0" ]] && grep -q "MARINE_PUBLIC_HTTP_SLEEP_SECONDS must be a nonnegative number" "$WORK/tun.log" \
  && ok "rejects negative MARINE_PUBLIC_HTTP_SLEEP_SECONDS" || { bad "negative sleep not rejected"; cat "$WORK/tun.log"; }

rc=0; ( export MARINE_DEPLOY_SOURCE_ONLY=1 MARINE_PUBLIC_HTTP_MAX_ATTEMPTS=2 MARINE_PUBLIC_HTTP_SLEEP_SECONDS=0.5
        source "$DEPLOY_SH" --check >"$WORK/tun.log" 2>&1 ) || rc=$?
[[ "$rc" == "0" ]] && ok "accepts positive attempts + fractional nonnegative sleep" || { bad "valid tunables rejected (rc=$rc)"; cat "$WORK/tun.log"; }

echo "== check_deploy_contract recreation-bypass matcher (unit) =="

# 11) The matcher must flag executable `docker compose up` / `--force-recreate` bypasses but
#     ignore comments/docs. Sourced with DEPLOY_CONTRACT_SOURCE_ONLY=1 so no tree scan runs.
mk() { printf '%s\n' "$2" >"$WORK/$1"; }
mk bypass_up.sh 'docker compose -f base.yml -f overlay.yml up -d rails sidekiq'
mk bypass_dc.sh 'docker-compose up --force-recreate'
mk bypass_recreate.sh '"$DOCKER" compose up -d --force-recreate rails'
mk comment_only.sh '# never run: docker compose up -d   (use deploy.sh instead)'
mk innocent.sh 'echo "setup cleanup: backup done"; docker compose config >/dev/null'
( export DEPLOY_CONTRACT_SOURCE_ONLY=1
  source "$CONTRACT_SH" >/dev/null 2>&1
  file_has_recreation_bypass "$WORK/bypass_up.sh"       || exit 31
  file_has_recreation_bypass "$WORK/bypass_dc.sh"       || exit 32
  file_has_recreation_bypass "$WORK/bypass_recreate.sh" || exit 33
  file_has_recreation_bypass "$WORK/comment_only.sh"    && exit 34
  file_has_recreation_bypass "$WORK/innocent.sh"        && exit 35
  exit 0
) && ok "recreation-bypass matcher flags executable up/force-recreate, ignores comments/docs" \
  || bad "recreation-bypass matcher (exit $?)"

# 13) retired-overlay reference scan: flags a plain file that references the retired needle,
#     ignores an identical reference under .hermes, and passes when no file references it.
#     Uses a needle assembled at runtime so this test file itself never matches.
RETIRED_NEEDLE="docker-compose.marine-""sop.yml"
mkdir -p "$WORK/ref/.hermes" "$WORK/ref/plain" "$WORK/ref/clean"
printf 'uses %s here\n' "$RETIRED_NEEDLE" >"$WORK/ref/plain/compose.txt"
printf 'uses %s here\n' "$RETIRED_NEEDLE" >"$WORK/ref/.hermes/snapshot.txt"
printf 'nothing to see\n' >"$WORK/ref/clean/compose.txt"
( export DEPLOY_CONTRACT_SOURCE_ONLY=1
  source "$CONTRACT_SH" >/dev/null 2>&1
  # Sourcing cd's to the repo root; move to the fixture dir so the repo-relative .hermes
  # exclusion glob (.hermes/*) matches the fixture path the same way it will in the tree.
  cd "$WORK/ref"
  retired_reference_in_list "$RETIRED_NEEDLE" "plain/compose.txt"    || exit 41
  retired_reference_in_list "$RETIRED_NEEDLE" ".hermes/snapshot.txt" && exit 42
  retired_reference_in_list "$RETIRED_NEEDLE" "clean/compose.txt"    && exit 44
  exit 0
) && ok "retired-reference scan flags plain refs, skips .hermes, passes when clean" \
  || bad "retired-reference scan (exit $?)"

echo "== domain-boundary monitor =="

run_monitor() { # <log-lines> -> exit code (stdout captured to out.log)
  local rc=0
  env MARINE_MONITOR_LOG_CMD="printf '%s' \"\$MON_LINES\"" MON_LINES="$1" \
    bash "$MONITOR_SH" --since 5m >"$WORK/mon.log" 2>>"$WORK/mon.log" || rc=$?
  echo "$rc"
}

# Internal dependency alert: fail-closed catalog error → nonzero.
rc="$(run_monitor '[Marine::Circuit::DomainBoundaryGuard] event=domain_boundary.fallback category=error')"
[[ "$rc" != "0" ]] && grep -q '"internal_dependency_alerts":1' "$WORK/mon.log" \
  && ok "monitor alerts on domain_boundary.fallback category=error" || { bad "monitor error alert"; cat "$WORK/mon.log"; }

# Internal dependency alert: CatalogUnavailableError → nonzero.
rc="$(run_monitor 'Marine::Catalog::Errors::CatalogUnavailableError: catalog unavailable')"
[[ "$rc" != "0" ]] && ok "monitor alerts on CatalogUnavailableError" || { bad "monitor CatalogUnavailableError"; cat "$WORK/mon.log"; }

# Legitimate semantic denial: unrelated → exit 0, NOT an internal alert.
rc="$(run_monitor '[Marine::Circuit::DomainBoundaryGuard] event=domain_boundary.deny category=unrelated')"
[[ "$rc" == "0" ]] && grep -q '"internal_dependency_alerts":0' "$WORK/mon.log" \
  && ok "monitor does NOT alert on category=unrelated (semantic denial)" || { bad "monitor unrelated denial"; cat "$WORK/mon.log"; }

# Legitimate semantic denials: extraction/override → exit 0.
rc="$(run_monitor '[g] event=domain_boundary.fallback category=extraction
[g] event=domain_boundary.deny category=override')"
[[ "$rc" == "0" ]] && ok "monitor does NOT alert on extraction/override denials" || { bad "monitor extraction/override"; cat "$WORK/mon.log"; }

# Mixed: a real error alongside a semantic denial still alerts (error dominates).
rc="$(run_monitor '[g] event=domain_boundary.deny category=unrelated
[g] event=domain_boundary.fallback category=error')"
[[ "$rc" != "0" ]] && ok "monitor alerts when an internal error coexists with a semantic denial" || { bad "monitor mixed case"; cat "$WORK/mon.log"; }

# Fail-closed on log collection failure: a nonzero log source must alert + exit nonzero and
# MUST NOT dump the raw captured stdout/stderr content. The seam prints a unique marker on
# both streams then exits nonzero; the marker must appear nowhere in the monitor output.
rc=0
env MARINE_MONITOR_LOG_CMD='printf "RAWLEAKSTDOUT\n"; printf "RAWLEAKSTDERR\n" >&2; exit 7' \
  bash "$MONITOR_SH" --since 5m >"$WORK/mon.log" 2>&1 || rc=$?
[[ "$rc" != "0" ]] \
  && ok "monitor exits nonzero when log collection fails (fail-closed)" \
  || { bad "monitor collection-failure exit (rc=$rc)"; cat "$WORK/mon.log"; }
grep -q 'log_collection_error' "$WORK/mon.log" && grep -q 'log collection failed' "$WORK/mon.log" \
  && ok "monitor emits an explicit secret-safe collection-error alert" \
  || { bad "monitor collection-error alert message"; cat "$WORK/mon.log"; }
grep -q 'RAWLEAK' "$WORK/mon.log" \
  && { bad "monitor leaked raw log input/error on collection failure"; cat "$WORK/mon.log"; } \
  || ok "monitor does not dump raw log input/error on collection failure"

echo "-------------------------------------------"
echo "PASS=$pass FAIL=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "Deployment-contract tests OK"
