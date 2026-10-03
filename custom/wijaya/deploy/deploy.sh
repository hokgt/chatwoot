#!/usr/bin/env bash
# =============================================================================
# Canonical Development deployment / recreation entrypoint for erp-dev.
#
#   THIS IS THE ONLY APPROVED WAY TO RECREATE OR DEPLOY rails / sidekiq /
#   marine_sop_worker ON erp-dev.
#
#   DO NOT run `docker compose ... up` (or `docker-compose up`) by hand to
#   recreate these services. A manual `up` with only the ignored local
#   docker-compose.deploy.yaml omits the MANDATORY Marine catalog secret
#   overlay, which drops the read-only catalog password mount from rails/
#   sidekiq. The catalog then fails closed (CatalogUnavailableError) and EVERY
#   non-product / non-exact-FAQ turn — greetings included — is denied via
#   domain_boundary with domain_boundary_category=error. This recurred on
#   2026-09-12 and 2026-09-16. This entrypoint exists to make that omission
#   impossible: it always layers the catalog overlay and refuses to proceed
#   unless the resolved rails+sidekiq models actually carry the read-only mount.
#
# Guarantees:
#   * always uses base docker-compose.deploy.yaml + the MANDATORY catalog overlay;
#   * optionally adds the SOP worker overlay only when explicitly enabled;
#   * preserves the currently-pinned images — never builds, never migrates;
#   * recreates ONLY the intended services (rails, sidekiq, optionally
#     marine_sop_worker) with --no-deps --force-recreate --no-build;
#   * rejects unsupported services/options — it is NOT a generic compose wrapper;
#   * never prints secret values or the host secret path.
#
# Modes:
#   --check   (default) non-mutating preflight only. Safe for CI/tests.
#   --deploy            run preflight, then recreate, then a post-deploy health gate.
#
# SOP worker (optional):
#   --with-sop-worker   include the SOP worker overlay + recreate marine_sop_worker.
#   (env MARINE_SOP_WORKER=1 is equivalent.)
#
# Usage:
#   custom/wijaya/deploy/deploy.sh --check
#   custom/wijaya/deploy/deploy.sh --deploy
#   MARINE_SOP_WORKER=1 custom/wijaya/deploy/deploy.sh --deploy --with-sop-worker
#
# Test seams (env; defaults resolve from the repo — do not use in production):
#   DOCKER                          docker binary (default: docker)
#   MARINE_DEPLOY_BASE_COMPOSE      base compose file path
#   MARINE_DEPLOY_CATALOG_OVERLAY   catalog overlay path
#   MARINE_DEPLOY_SOP_OVERLAY       sop-worker overlay path
# =============================================================================
set -euo pipefail

readonly EXPECTED_BRANCH='devbot'
readonly EXPECTED_REMOTE='git@github.com:hokgt/chatwoot.git'
readonly CATALOG_ENV_KEY='MARINE_CATALOG_PG_PASSWORD_FILE'
readonly PUBLIC_HEALTH_URL='https://chatwoot.wijayacorp.com/'
readonly ALLOWED_SERVICES=('rails' 'sidekiq' 'marine_sop_worker')

# Unique, allowlisted sentinel markers. The in-container Rails runners emit exactly one
# sentinel line each; the shell extracts ONLY that anchored line and ignores any Rails
# boot warnings/info printed to stdout. We never echo broad runner output or secrets.
readonly CATALOG_GATE_SENTINEL='MARINE_CATALOG_GATE'
readonly PROBE_SENTINEL='MARINE_PROBE'

DOCKER="${DOCKER:-docker}"
# curl/sleep are injectable so the readiness retry can be exercised without real HTTP.
CURL="${MARINE_CURL:-curl}"
SLEEP="${MARINE_SLEEP:-sleep}"
# Bounded public-HTTP readiness retry (Rails may need a few seconds to boot).
PUBLIC_HTTP_MAX_ATTEMPTS="${MARINE_PUBLIC_HTTP_MAX_ATTEMPTS:-10}"
PUBLIC_HTTP_SLEEP_SECONDS="${MARINE_PUBLIC_HTTP_SLEEP_SECONDS:-3}"

log()  { printf '[deploy] %s\n' "$*" >&2; }
ok()   { printf '[deploy] PASS %s\n' "$*" >&2; }
die()  { printf '[deploy] FAIL %s\n' "$*" >&2; exit 1; }

# Validate the readiness-retry tunables up front so a malformed override fails safely with an
# explicit message instead of silently corrupting the bounded retry arithmetic below.
validate_readiness_tunables() {
  [[ "$PUBLIC_HTTP_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
    || die "MARINE_PUBLIC_HTTP_MAX_ATTEMPTS must be a positive integer (got '$PUBLIC_HTTP_MAX_ATTEMPTS')"
  [[ "$PUBLIC_HTTP_SLEEP_SECONDS" =~ ^([0-9]+|[0-9]*\.[0-9]+)$ ]] \
    || die "MARINE_PUBLIC_HTTP_SLEEP_SECONDS must be a nonnegative number (got '$PUBLIC_HTTP_SLEEP_SECONDS')"
}
validate_readiness_tunables

# ---------------------------------------------------------------------------
# Resolve repo root robustly (git first, then walk up from this script).
# ---------------------------------------------------------------------------
resolve_repo_root() {
  local script_dir root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$root"
    return 0
  fi
  # Fallback: this file lives at <root>/custom/wijaya/deploy/deploy.sh
  ( cd "$script_dir/../../.." && pwd )
}

REPO_ROOT="$(resolve_repo_root)"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT" ]] || die "could not resolve repository root"
cd "$REPO_ROOT"

BASE_COMPOSE="${MARINE_DEPLOY_BASE_COMPOSE:-$REPO_ROOT/docker-compose.deploy.yaml}"
CATALOG_OVERLAY="${MARINE_DEPLOY_CATALOG_OVERLAY:-$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-catalog.yml}"
SOP_OVERLAY="${MARINE_DEPLOY_SOP_OVERLAY:-$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-sop-worker.yml}"

# ---------------------------------------------------------------------------
# Argument parsing — strict whitelist, no generic passthrough.
# ---------------------------------------------------------------------------
MODE='check'
WITH_SOP="${MARINE_SOP_WORKER:-0}"
[[ "$WITH_SOP" == '1' ]] && WITH_SOP=1 || WITH_SOP=0
REQUESTED_SERVICES=()

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)           MODE='check' ;;
      --deploy)          MODE='deploy' ;;
      --with-sop-worker) WITH_SOP=1 ;;
      --service)
        shift || die "--service requires a value"
        [[ $# -gt 0 ]] || die "--service requires a value"
        REQUESTED_SERVICES+=("$1")
        ;;
      -h|--help)
        sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
        exit 0
        ;;
      --*|-*) die "unsupported option: $1 (this is not a generic compose wrapper)" ;;
      *)      die "unexpected argument: $1" ;;
    esac
    shift
  done
}
parse_args "$@"

is_allowed_service() {
  local s="$1" a
  for a in "${ALLOWED_SERVICES[@]}"; do [[ "$s" == "$a" ]] && return 0; done
  return 1
}

# Determine the exact set of services to recreate.
TARGET_SERVICES=('rails' 'sidekiq')
[[ "$WITH_SOP" -eq 1 ]] && TARGET_SERVICES+=('marine_sop_worker')

if [[ "${#REQUESTED_SERVICES[@]}" -gt 0 ]]; then
  local_selection=()
  for s in "${REQUESTED_SERVICES[@]}"; do
    is_allowed_service "$s" || die "unsupported service: $s (allowed: ${ALLOWED_SERVICES[*]})"
    if [[ "$s" == 'marine_sop_worker' && "$WITH_SOP" -ne 1 ]]; then
      die "service marine_sop_worker requires --with-sop-worker (or MARINE_SOP_WORKER=1)"
    fi
    local_selection+=("$s")
  done
  TARGET_SERVICES=("${local_selection[@]}")
fi

# Compose file argument vector — base + MANDATORY catalog, then optional SOP.
COMPOSE_ARGS=(-f "$BASE_COMPOSE" -f "$CATALOG_OVERLAY")
[[ "$WITH_SOP" -eq 1 ]] && COMPOSE_ARGS+=(-f "$SOP_OVERLAY")

compose() { "$DOCKER" compose "${COMPOSE_ARGS[@]}" "$@"; }

# ---------------------------------------------------------------------------
# 0) Tooling + project/branch/remote validation.
# ---------------------------------------------------------------------------
validate_tools() {
  command -v "$DOCKER" >/dev/null 2>&1 || die "docker binary not found: $DOCKER"
  "$DOCKER" compose version >/dev/null 2>&1 || die "docker compose plugin not available"
  command -v jq >/dev/null 2>&1 || die "jq is required for config validation"
  command -v git >/dev/null 2>&1 || die "git is required"
  ok "required tools present"
}

validate_project() {
  local branch remote
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ "$branch" == "$EXPECTED_BRANCH" ]] || die "branch is '$branch', expected '$EXPECTED_BRANCH'"
  remote="$(git remote get-url origin 2>/dev/null || true)"
  [[ "$remote" == "$EXPECTED_REMOTE" ]] || die "origin remote is not the approved repository"
  ok "project on branch '$EXPECTED_BRANCH' with approved origin"
}

# ---------------------------------------------------------------------------
# 1) Preflight — fail BEFORE any compose `up`.
# ---------------------------------------------------------------------------
validate_overlay_files() {
  # The MANDATORY catalog overlay must be present in the file list and on disk.
  local seen=0 f
  for f in "${COMPOSE_ARGS[@]}"; do
    [[ "$f" == "$CATALOG_OVERLAY" ]] && seen=1
  done
  [[ "$seen" -eq 1 ]] || die "mandatory catalog overlay absent from compose file list"
  [[ -f "$BASE_COMPOSE" ]]    || die "base compose file is missing"
  [[ -s "$CATALOG_OVERLAY" ]] || die "mandatory catalog overlay is missing or empty"
  if [[ "$WITH_SOP" -eq 1 ]]; then
    [[ -s "$SOP_OVERLAY" ]] || die "SOP worker overlay is missing or empty"
    # The optional SOP overlay must NOT carry the rails/sidekiq catalog mount.
    if grep -q "$CATALOG_ENV_KEY" "$SOP_OVERLAY" 2>/dev/null; then
      die "SOP worker overlay must not reference the catalog secret"
    fi
  fi
  ok "compose overlays resolved (catalog mandatory$([[ "$WITH_SOP" -eq 1 ]] && echo ', sop enabled'))"
}

# Emit the resolved, merged compose config as JSON (empty on failure).
resolve_config_json() {
  compose config --format json 2>/dev/null || true
}

# Verify a service model carries the catalog env + a matching read-only bind mount,
# and that the resolved HOST source file is a readable, non-empty regular file.
# Never prints the source path or any secret value.
validate_service_catalog_contract() {
  local json="$1" svc="$2" env_path ro src
  env_path="$(jq -r --arg s "$svc" '.services[$s].environment[$k] // empty' --arg k "$CATALOG_ENV_KEY" <<<"$json")"
  [[ -n "$env_path" ]] || die "$svc is missing $CATALOG_ENV_KEY in the resolved config"

  ro="$(jq -r --arg s "$svc" --arg t "$env_path" '
    (.services[$s].volumes // [])
    | map(select(.type=="bind" and .target==$t))
    | if length==0 then "NOMOUNT"
      elif (map(.read_only==true) | all) then "RO"
      else "RW" end' <<<"$json")"
  case "$ro" in
    RO)      : ;;
    NOMOUNT) die "$svc has no catalog bind mount at its configured container path" ;;
    RW)      die "$svc catalog mount is not read-only" ;;
    *)       die "$svc catalog mount could not be evaluated" ;;
  esac

  src="$(jq -r --arg s "$svc" --arg t "$env_path" '
    (.services[$s].volumes // [])
    | map(select(.type=="bind" and .target==$t)) | .[0].source // empty' <<<"$json")"
  [[ -n "$src" ]]  || die "$svc catalog mount has no resolved host source"
  [[ -f "$src" ]]  || die "catalog secret file is missing or not a regular file"
  [[ -r "$src" ]]  || die "catalog secret file is not readable"
  [[ -s "$src" ]]  || die "catalog secret file is empty"
  ok "$svc carries a read-only catalog mount backed by a non-empty host file"
}

preflight() {
  validate_overlay_files
  local json
  json="$(resolve_config_json)"
  [[ -n "$json" ]] || die "resolved compose config is empty or invalid"
  jq -e . >/dev/null 2>&1 <<<"$json" || die "resolved compose config is not valid JSON"
  ok "resolved compose config is valid"

  # Catalog contract is enforced on BOTH request-serving services.
  validate_service_catalog_contract "$json" 'rails'
  validate_service_catalog_contract "$json" 'sidekiq'

  # The SOP worker (if enabled) must NOT carry the catalog mount.
  if [[ "$WITH_SOP" -eq 1 ]]; then
    local sop_mounts
    sop_mounts="$(jq -r --arg k "$CATALOG_ENV_KEY" '
      (.services["marine_sop_worker"].environment[$k] // "")' <<<"$json")"
    [[ -z "$sop_mounts" ]] || die "marine_sop_worker must not carry the catalog secret"
    ok "marine_sop_worker is free of the catalog secret"
  fi
}

# ---------------------------------------------------------------------------
# 2) Image safety — images must already exist locally (no build).
# ---------------------------------------------------------------------------
validate_images_present() {
  local json="$1" svc image
  for svc in "${TARGET_SERVICES[@]}"; do
    image="$(jq -r --arg s "$svc" '.services[$s].image // empty' <<<"$json")"
    [[ -n "$image" ]] || die "$svc has no resolved image (refusing to build)"
    "$DOCKER" image inspect "$image" >/dev/null 2>&1 || die "$svc image is not present locally (refusing to build)"
  done
  ok "target service images present locally"
}

# ---------------------------------------------------------------------------
# 3) Recreation — the ONLY mutating step.
# ---------------------------------------------------------------------------
recreate_services() {
  log "recreating: ${TARGET_SERVICES[*]}"
  compose up -d --no-deps --force-recreate --no-build "${TARGET_SERVICES[@]}"
  ok "services recreated"
}

# ---------------------------------------------------------------------------
# 4) Post-deploy health gate.
# ---------------------------------------------------------------------------
container_id() { compose ps -q "$1" 2>/dev/null; }

gate_config_files_label() {
  local svc cid labels f
  for svc in rails sidekiq; do
    cid="$(container_id "$svc")"
    [[ -n "$cid" ]] || die "$svc container not running after recreation"
    labels="$("$DOCKER" inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$cid" 2>/dev/null || true)"
    grep -qF "$BASE_COMPOSE" <<<"$labels"    || die "$svc config_files label is missing the base compose file"
    grep -qF "$CATALOG_OVERLAY" <<<"$labels" || die "$svc config_files label is missing the mandatory catalog overlay"
    if [[ "$WITH_SOP" -eq 1 ]]; then
      grep -qF "$SOP_OVERLAY" <<<"$labels" || die "$svc config_files label is missing the SOP overlay"
    fi
  done
  ok "rails+sidekiq labelled with base + mandatory catalog overlay"
}

gate_password_file_and_mount() {
  local svc cid env_path dest_ro
  for svc in rails sidekiq; do
    cid="$(container_id "$svc")"
    [[ -n "$cid" ]] || die "$svc container not running"
    # File is present, readable and non-empty INSIDE the container (no content printed).
    if ! "$DOCKER" exec -e KEY="$CATALOG_ENV_KEY" "$cid" sh -c '
        p="$(printenv "$KEY")"; [ -n "$p" ] && [ -f "$p" ] && [ -r "$p" ] && [ -s "$p" ]'; then
      die "$svc catalog password file is absent/unreadable/empty inside the container"
    fi
    # Matching read-only mount per docker inspect.
    env_path="$("$DOCKER" exec -e KEY="$CATALOG_ENV_KEY" "$cid" sh -c 'printenv "$KEY"' 2>/dev/null || true)"
    dest_ro="$("$DOCKER" inspect --format '{{range .Mounts}}{{if eq .Destination "'"$env_path"'"}}{{.RW}}{{end}}{{end}}' "$cid" 2>/dev/null || true)"
    [[ -n "$dest_ro" ]] || die "$svc has no mount at the catalog password path"
    [[ "$dest_ro" == 'false' ]] || die "$svc catalog mount is not read-only"
  done
  ok "catalog password file present + read-only inside rails+sidekiq"
}

# --- Pure sentinel parsers (no docker; unit-tested by the regression suite) ---------
# Extract the single allowlisted catalog-gate verdict from raw runner output, ignoring
# any Rails boot noise on stdout. Echoes 'PASS' or 'FAIL'; empty when no sentinel line.
parse_catalog_gate_verdict() {
  local raw="$1" line
  line="$(grep -m1 -E "^${CATALOG_GATE_SENTINEL}:" <<<"$raw" | tr -d '[:space:]' || true)"
  [[ -n "$line" ]] || { printf ''; return 0; }
  case "${line#"${CATALOG_GATE_SENTINEL}":}" in
    PASS) printf 'PASS' ;;
    *)    printf 'FAIL' ;;
  esac
}

# Evaluate the domain-boundary probe sentinel line. Echoes 'OK' only when both categories
# are healthy AND all three persistence deltas are exactly zero AND the transaction-rollback
# marker (ROLLBACK=1) is present; otherwise a short reason token. Reads only allowlisted
# category words + integer deltas + the rollback marker — never model/customer text.
evaluate_probe_sentinel() {
  local raw="$1" line greet unrel dconv dmsg dresp rollback
  line="$(grep -m1 -E "^${PROBE_SENTINEL}:" <<<"$raw" || true)"
  [[ -n "$line" ]] || { printf 'no-sentinel'; return 0; }
  greet="$(sed -n 's/.*GREET=\([a-z_]*\).*/\1/p' <<<"$line")"
  unrel="$(sed -n 's/.*UNREL=\([a-z_]*\).*/\1/p' <<<"$line")"
  dconv="$(sed -n 's/.*DCONV=\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' <<<"$line")"
  dmsg="$(sed -n 's/.*DMSG=\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' <<<"$line")"
  dresp="$(sed -n 's/.*DRESP=\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' <<<"$line")"
  rollback="$(sed -n 's/.*ROLLBACK=\([0-9]\{1,\}\).*/\1/p' <<<"$line")"
  [[ -n "$greet" ]] || { printf 'no-greet'; return 0; }
  [[ "$greet" != 'error' ]] || { printf 'greet-error'; return 0; }
  [[ "$unrel" != 'error' ]] || { printf 'unrel-error'; return 0; }
  [[ "$unrel" == 'unrelated' ]] || { printf 'unrel-not-denied'; return 0; }
  [[ -n "$dconv" && -n "$dmsg" && -n "$dresp" ]] || { printf 'no-deltas'; return 0; }
  [[ "$dconv" -eq 0 && "$dmsg" -eq 0 && "$dresp" -eq 0 ]] || { printf 'persisted'; return 0; }
  [[ "$rollback" == '1' ]] || { printf 'no-rollback'; return 0; }
  printf 'OK'
}

gate_catalog_reference() {
  local svc cid raw verdict
  for svc in rails sidekiq; do
    cid="$(container_id "$svc")"
    [[ -n "$cid" ]] || die "$svc container not running for catalog-reference gate"
    # The runner emits exactly one anchored sentinel line; boot warnings/info on stdout
    # are ignored by the parser. Exception details are never surfaced to the operator.
    raw="$("$DOCKER" exec "$cid" bundle exec rails runner '
      m = "'"$CATALOG_GATE_SENTINEL"'"
      begin
        Marine::Circuit::CatalogDomainReference.new.block
        puts "#{m}:PASS"
      rescue => e
        puts "#{m}:FAIL:#{e.class}"
      end' 2>/dev/null || true)"
    verdict="$(parse_catalog_gate_verdict "$raw")"
    [[ -n "$verdict" ]]      || die "$svc catalog-reference gate emitted no sentinel"
    [[ "$verdict" == 'PASS' ]] || die "$svc CatalogDomainReference did not build"
  done
  ok "CatalogDomainReference builds in rails+sidekiq"
}

gate_domain_boundary_probe() {
  # Synthetic, non-delivering probes through the shared guard. The guard should return a
  # decision payload WITHOUT persisting anything. We PROVE that by snapshotting row counts
  # for Conversations, Messages and Marine::AssistantResponse before/after in the SAME
  # runner process and asserting every delta is zero.
  #
  # Both guard calls AND the before/after snapshots run inside ONE
  # REPEATABLE READ transaction that is then deliberately rolled back
  # (raise ActiveRecord::Rollback). This makes the probe non-delivering by construction —
  # nothing this connection touches can persist — and, under repeatable-read, the snapshot
  # deltas stay stable even while other connections commit real traffic concurrently (no
  # live-traffic race). The sentinel is composed inside the transaction, carried out in a
  # variable, and emitted only AFTER the rollback, with an allowlisted ROLLBACK=1 marker the
  # parser requires. We print only allowlisted category words + integer deltas + the rollback
  # marker — never model output or customer data.
  local cid raw verdict
  cid="$(container_id rails)"
  [[ -n "$cid" ]] || die "rails container not running for domain-boundary probe"
  raw="$("$DOCKER" exec "$cid" bundle exec rails runner '
    m = "'"$PROBE_SENTINEL"'"
    asst = Marine::Assistant.first
    abort("#{m}:NOASSISTANT") unless asst
    acct = asst.respond_to?(:account) ? asst.account : nil
    snap = lambda do
      { conv: Conversation.count,
        msg:  Message.count,
        resp: Marine::AssistantResponse.count }
    end
    sentinel = nil
    ActiveRecord::Base.transaction(isolation: :repeatable_read, requires_new: true) do
      before = snap.call
      guard = Marine::Circuit::DomainBoundaryGuard.new(assistant: asst, account: acct)
      g = guard.call(query: "Hello, Min", history: [])
      u = guard.call(query: "What is the capital of France?", history: [])
      after = snap.call
      gcat = g.is_a?(Hash) ? g["domain_boundary_category"].to_s : "allow"
      ucat = u.is_a?(Hash) ? u["domain_boundary_category"].to_s : "allow"
      sentinel = format("%s:GREET=%s UNREL=%s DCONV=%d DMSG=%d DRESP=%d ROLLBACK=1", m, gcat, ucat,
                        after[:conv]-before[:conv], after[:msg]-before[:msg], after[:resp]-before[:resp])
      raise ActiveRecord::Rollback
    end
    puts sentinel if sentinel
  ' 2>/dev/null || true)"
  verdict="$(evaluate_probe_sentinel "$raw")"
  case "$verdict" in
    OK)               ok "domain boundary probes healthy (greeting not error; unrelated denied; zero persistence; rolled back)" ;;
    greet-error)      die "greeting probe returned domain_boundary_category=error (internal domain-boundary dependency failure: catalog, LLM provider/config, or malformed output)" ;;
    unrel-error)      die "unrelated probe returned category=error instead of a semantic denial" ;;
    unrel-not-denied) die "unrelated probe was not semantically denied as 'unrelated'" ;;
    persisted)        die "domain boundary probe left persistent records (nonzero conversation/message/response delta)" ;;
    no-deltas)        die "domain boundary probe did not report persistence deltas" ;;
    no-rollback)      die "domain boundary probe did not confirm transaction rollback (ROLLBACK marker absent)" ;;
    no-greet|no-sentinel) die "domain boundary probe produced no result" ;;
    *)                die "domain boundary probe verdict could not be evaluated" ;;
  esac
}

gate_public_http() {
  # Bounded readiness retry: Rails may legitimately need a few seconds to accept traffic
  # after force-recreation. Fail explicitly if no HTTP 200 within the attempt budget.
  local attempt code=''
  for (( attempt=1; attempt<=PUBLIC_HTTP_MAX_ATTEMPTS; attempt++ )); do
    code="$("$CURL" -fsS -o /dev/null -w '%{http_code}' --max-time 20 "$PUBLIC_HEALTH_URL" 2>/dev/null || true)"
    if [[ "$code" == '200' ]]; then
      ok "public endpoint returned HTTP 200 (attempt $attempt/$PUBLIC_HTTP_MAX_ATTEMPTS)"
      return 0
    fi
    [[ "$attempt" -lt "$PUBLIC_HTTP_MAX_ATTEMPTS" ]] && "$SLEEP" "$PUBLIC_HTTP_SLEEP_SECONDS"
  done
  die "public health URL did not return 200 within $PUBLIC_HTTP_MAX_ATTEMPTS attempts (last '${code:-none}')"
}

gate_deployment_window_logs() {
  # Inspect ONLY the bounded deployment window so historical errors never cause a
  # permanent false failure. Delegates to the secret-safe monitor.
  local since="$1" monitor
  monitor="$REPO_ROOT/custom/wijaya/scripts/marine_domain_boundary_monitor.sh"
  [[ -x "$monitor" ]] || { log "monitor script not executable; skipping log-window gate"; return 0; }
  DOCKER="$DOCKER" MARINE_DEPLOY_BASE_COMPOSE="$BASE_COMPOSE" \
    MARINE_DEPLOY_CATALOG_OVERLAY="$CATALOG_OVERLAY" \
    "$monitor" --since "$since" \
    || die "deployment-window logs show an internal dependency alert"
  ok "deployment-window logs free of internal dependency alerts"
}

health_gate() {
  local since="$1"
  gate_config_files_label
  gate_password_file_and_mount
  gate_catalog_reference
  gate_domain_boundary_probe
  gate_deployment_window_logs "$since"
  gate_public_http
  ok "post-deploy health gate PASSED"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  validate_tools
  validate_project
  preflight

  if [[ "$MODE" == 'check' ]]; then
    ok "preflight-only (--check) complete; no services were recreated"
    exit 0
  fi

  local json since
  json="$(resolve_config_json)"
  validate_images_present "$json"
  since="$(date +%s)"
  recreate_services
  health_gate "$since"
  ok "deploy complete"
}

# Run the pipeline unless sourced for unit testing (the regression suite sources this
# file with MARINE_DEPLOY_SOURCE_ONLY=1 to exercise the pure parsers / retry loop).
if [[ "${MARINE_DEPLOY_SOURCE_ONLY:-0}" != "1" ]]; then
  main
fi
