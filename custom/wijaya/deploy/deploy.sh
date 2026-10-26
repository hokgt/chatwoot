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
#   --check    (default) non-mutating preflight only. Safe for CI/tests.
#   --deploy             APP deploy (rails+sidekiq, indivisible): prove the CURRENT app
#                        runtime is known-good, record the fixed app rollback receipt
#                        (atomically, BEFORE recreation), recreate, then a post-deploy health
#                        gate. Any recreation/health failure triggers exactly ONE automatic
#                        rollback to that receipt and still exits with the original status.
#                        SOP-only deploy (--with-sop-worker --service marine_sop_worker) keeps
#                        its existing behavior and carries NO receipt / NO auto-rollback. A
#                        combined app+SOP deploy is refused (atomic cross-scope rollback is
#                        unsupported) — deploy the app and the SOP worker in separate runs.
#   --rollback           APP-only: re-pin the EXACT immutable app image ID recorded in the
#                        receipt, force-recreate rails+sidekiq with no build/dependency work
#                        (the mandatory overlays are unchanged across releases), and re-run the
#                        existing runtime gates. The receipt is left UNCHANGED (idempotent).
#                        --rollback rejects --with-sop-worker and --service.
#
# SOP worker (optional, deploy only):
#   --with-sop-worker   include the SOP worker overlay + recreate marine_sop_worker.
#   (env MARINE_SOP_WORKER=1 is equivalent.)
#
# Usage:
#   custom/wijaya/deploy/deploy.sh --check
#   custom/wijaya/deploy/deploy.sh --deploy
#   custom/wijaya/deploy/deploy.sh --rollback
#   MARINE_SOP_WORKER=1 custom/wijaya/deploy/deploy.sh --deploy --with-sop-worker --service marine_sop_worker
#
# Test seams (env; defaults resolve from the repo — do not use in production):
#   DOCKER                          docker binary (default: docker)
#   MARINE_DEPLOY_BASE_COMPOSE      base compose file path
#   MARINE_DEPLOY_CATALOG_OVERLAY   catalog overlay path
#   MARINE_DEPLOY_SOP_OVERLAY       sop-worker overlay path
# Tests run against disposable repository copies and inject only fake Docker/curl binaries.
# =============================================================================
set -euo pipefail

readonly EXPECTED_BRANCH='devbot'
readonly EXPECTED_REMOTE='git@github.com:hokgt/chatwoot.git'
readonly CATALOG_ENV_KEY='MARINE_CATALOG_PG_PASSWORD_FILE'
readonly PUBLIC_HEALTH_URL='https://chatwoot.wijayacorp.com/'
readonly ALLOWED_SERVICES=('rails' 'sidekiq' 'marine_sop_worker')
readonly SOP_ROLE_LABEL='com.wijaya.chatwoot.role'
readonly SOP_SOURCE_LABEL='org.opencontainers.image.revision'
readonly SOP_BASE_IMAGE_LABEL='com.wijaya.chatwoot.base-image'
readonly SOP_OVERLAY_LABEL='com.wijaya.chatwoot.overlay'
readonly SOP_ROLE='marine_sop_worker'
readonly SOP_OVERLAY_ID='custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-sop-worker.yml'

# Finding 2 — the receipt-backed app (rails+sidekiq) recreation feeds its fully-resolved Compose
# config to `compose up` on stdin (-f -) so Compose can never reopen a mutable asset path after
# validation. Stdin config carries no config_files path provenance, so each app service gets a
# stable, non-secret Wijaya source-revision + config-hash label that runtime health validates
# against the embedded runtime SHA and the trusted git blobs instead of config_files paths.
readonly COMPOSE_SOURCE_REVISION_LABEL='com.wijaya.chatwoot.compose-source-revision'
readonly COMPOSE_CONFIG_HASH_LABEL='com.wijaya.chatwoot.compose-config-sha256'

# Canonical APP receipt-backed rollback. There is ONE fixed receipt file, app.json (never an
# input-derived name). An app --deploy proves the CURRENT app runtime is known-good, then records
# that pre-deploy runtime into app.json — allowlisted non-secret fields only: schema version, the
# captured app image's embedded Git SHA, its immutable image ID, the fixed [rails, sidekiq]
# service pair, and sha256 fingerprints of the two mandatory compose overlays — in a fixed,
# ignored, 0700 repo-local directory, atomically BEFORE the real `compose up`. The receipt is the
# IMMEDIATE rollback authority: no pending/promotion state exists. A recreation/health failure
# auto-rolls-back to it exactly once; the next successful app deploy overwrites it. --rollback
# leaves it unchanged (idempotent). The receipt NEVER stores secrets or host paths.
readonly RECEIPT_SCHEMA_VERSION=1
readonly RECEIPT_APP_NAME='app.json'

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

# ===========================================================================
# EXCLUSIVE LIFECYCLE LOCK — established BEFORE any readiness/git/repo/project/
# tool/receipt/runtime state read below.
#
# Retained-lock ordering contract: an app --deploy or an explicit --rollback (the only two
# scopes that mutate the request-serving runtime) must already be running under the fixed
# exclusive lock BEFORE this script validates readiness tunables, resolves the repo root with
# git, changes directory, parses arguments, or reads any project/tool/receipt/runtime state.
# The decision uses fixed argv/env ALONE, and the helper path is derived from this script's own
# location (no git/project probe). First pass: re-exec through the receipt helper's lock-exec,
# which opens+validates+flocks the fixed lock through an openat/O_NOFOLLOW directory fd and
# re-execs us with the locked fd inherited. Second pass: the inherited retained fd is VALIDATED
# (fstat type/owner/mode + flock, never a numeric marker alone, never reopening the lock
# pathname) and initialization then continues exactly once.
# ===========================================================================
__early_script_dir() { ( CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd ); }

# Decide from fixed argv/env ALONE whether this invocation must hold the lifecycle lock. No
# filesystem/git/project/tool/state read happens here — only argv scanning. Returns 0 (lock
# required) for an explicit --rollback and for any app --deploy; returns non-zero for --check and
# for a SOP-only deploy (every --service value is marine_sop_worker), which stay lock-free.
__invocation_needs_lifecycle_lock() {
  local mode='check' saw_service=0 all_sop=1 want_service=0 a
  for a in "$@"; do
    if [[ "$want_service" -eq 1 ]]; then
      want_service=0; saw_service=1
      [[ "$a" == 'marine_sop_worker' ]] || all_sop=0
      continue
    fi
    case "$a" in
      --check)    mode='check' ;;
      --deploy)   mode='deploy' ;;
      --rollback) mode='rollback' ;;
      --service)  want_service=1 ;;
      *)          : ;;  # all argument validation happens later, under the lock
    esac
  done
  [[ "$mode" == 'rollback' ]] && return 0
  if [[ "$mode" == 'deploy' ]]; then
    # SOP-only deploy (--service restricted to marine_sop_worker) stays lock-free; the default
    # deploy and any rails/sidekiq selection include the app and MUST hold the lock.
    [[ "$saw_service" -eq 1 && "$all_sop" -eq 1 ]] && return 1
    return 0
  fi
  return 1
}

enter_lifecycle_lock_before_any_read() {
  __invocation_needs_lifecycle_lock "$@" || return 0
  local helper; helper="$(__early_script_dir)/receipt.py"
  if [[ -n "${MARINE_LIFECYCLE_LOCK_FD:-}" ]]; then
    # Second pass: NEVER trust the numeric marker alone and NEVER reopen the lock pathname.
    # Validate the INHERITED retained fd itself (fstat type/owner/mode + flock) through the
    # helper, then continue initialization exactly once.
    [[ "$MARINE_LIFECYCLE_LOCK_FD" =~ ^[0-9]+$ ]] || die "invalid inherited lifecycle lock fd"
    python3 "$helper" verify-inherited-fd "$MARINE_LIFECYCLE_LOCK_FD" >/dev/null 2>&1 \
      || die "inherited lifecycle lock fd failed validation (forged/closed/unlocked marker refused)"
    LIFECYCLE_LOCK_FD="$MARINE_LIFECYCLE_LOCK_FD"
    ok "running under the exclusive deploy/rollback lifecycle lock (validated inherited fd $LIFECYCLE_LOCK_FD)"
    return 0
  fi
  # First pass: hand off to the helper to open+validate+flock the fixed lock and re-exec us with
  # the locked fd inherited — BEFORE this script performs any state read.
  exec python3 "$helper" lock-exec "${BASH_SOURCE[0]}" "$@"
}
# Run the gate before ANY state read. Skipped only when the script is merely SOURCED for unit
# testing (MARINE_DEPLOY_SOURCE_ONLY=1), which performs no mutation.
if [[ "${MARINE_DEPLOY_SOURCE_ONLY:-0}" != "1" ]]; then
  enter_lifecycle_lock_before_any_read "$@"
fi

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
SOP_SANDBOX_GATE="$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/sop_sandbox_gate.sh"

# The base + catalog files actually handed to `compose up`. For an app deploy/rollback these are
# repointed to the immutable per-commit assets materialized under the receipt dir (below); a
# SOP-only deploy keeps the working-tree files. Fixed basenames mirror the repository filenames.
readonly ASSET_BASE_BASENAME='docker-compose.deploy.yaml'
readonly ASSET_CATALOG_BASENAME='docker-compose.marine-catalog.yml'
ACTIVE_BASE="$BASE_COMPOSE"
ACTIVE_CATALOG="$CATALOG_OVERLAY"
ASSET_BASE=''
ASSET_CATALOG=''

# Fixed production receipt and lifecycle lock. Tests exercise a disposable copy of this script
# and repository fixture, so production has no path override or mutation-capable test mode.
readonly RECEIPT_DIR="$REPO_ROOT/custom/wijaya/deploy/.receipts"
readonly RECEIPT_FILE="$RECEIPT_DIR/$RECEIPT_APP_NAME"
# Persistent per-commit compose assets live here, keyed by full commit: <assets>/<sha>/<basename>.
readonly RECEIPT_ASSETS_DIR="$RECEIPT_DIR/assets"
# Preserve any value the early lifecycle-lock gate already validated and set on the second pass;
# only default it when the gate did not run (e.g. --check / SOP-only / source-only).
LIFECYCLE_LOCK_FD="${LIFECYCLE_LOCK_FD:-}"
# Battery-owned helper that owns canonical JSON, O_NOFOLLOW reads, owner/mode checks, strict
# validation, hashing, and the atomic fsync write. Bash orchestrates Docker/Compose only.
RECEIPT_HELPER="$REPO_ROOT/custom/wijaya/deploy/receipt.py"

# Rollback receipt fields, populated by load_rollback_receipt from the validated receipt, plus
# the forward-deploy fingerprints remembered for the immediately-before-compose-up recheck.
RB_TARGET_SHA=''
RB_APP_IMAGE_ID=''
RB_SERVICES=()
RB_FP_BASE=''
RB_FP_CATALOG=''
# Set only on the AUTOMATIC rollback path to the NEW image just attempted, so the rollback refuses
# a receipt whose image equals NEW (there would be nothing to roll back to). Unset for explicit
# --rollback, which never compares against a NEW image.
ROLLBACK_DISTINCT_FROM=''

# Blocker 3 (final independent review): the immutable image ID of the SOP
# derivative verified BEFORE recreation (distinct from the app image ID, matching
# OCI provenance labels, and a nonempty embedded /app/.git_sha read from the ID
# itself, never from the mutable tag). The pre-image sandbox gate and compose up
# are both pinned to this exact ID (exported as MARINE_SOP_IMAGE, overriding any
# operator-provided tag), so the gate, the recreation and every post-runtime
# check run the SAME immutable image content — no tag-retarget TOCTOU remains.
SOP_VERIFIED_IMAGE_ID=''
APP_VERIFIED_IMAGE_ID=''
# Finding 2 — the EXACT resolved app compose config retained in memory (never persisted to disk or
# printed) and fed to `compose up` on stdin. Empty for a SOP-only deploy, which keeps the
# file-based compose invocation.
APP_CAPTURED_COMPOSE=''

# G2: the deployed app image MUST embed the exact checked-out repository HEAD.
# This is intentionally not operator-overridable: allowing a separately supplied
# target SHA would let a stale image validate against a value unrelated to the
# checkout being deployed. Resolved only inside the LOCKED deploy path (not at
# top level) so no lifecycle HEAD read ever happens before the exclusive lock.
APP_EXPECTED_GIT_SHA=''

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
      --rollback)        MODE='rollback' ;;
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
# Remember the exact original argv so the lifecycle-lock helper can faithfully re-exec this
# script under the held lock (the only lifecycle re-exec; the env marker prevents recursion).
ORIGINAL_ARGS=("$@")
parse_args "$@"

is_allowed_service() {
  local s="$1" a
  for a in "${ALLOWED_SERVICES[@]}"; do [[ "$s" == "$a" ]] && return 0; done
  return 1
}

target_selected() {
  local wanted="$1" selected
  for selected in "${TARGET_SERVICES[@]}"; do [[ "$selected" == "$wanted" ]] && return 0; done
  return 1
}

# Determine the exact set of services to recreate.
TARGET_SERVICES=('rails' 'sidekiq')
[[ "$WITH_SOP" -eq 1 ]] && TARGET_SERVICES+=('marine_sop_worker')

if [[ "${#REQUESTED_SERVICES[@]}" -gt 0 ]]; then
  local_selection=()
  for s in "${REQUESTED_SERVICES[@]}"; do
    is_allowed_service "$s" || die "unsupported service: $s (allowed: ${ALLOWED_SERVICES[*]})"
    # The request-serving app is an indivisible pair: rails + sidekiq always deploy together so
    # a receipt (and its rollback) can never pin a half-updated app runtime. Only the optional
    # SOP worker may be deployed on its own. Service-scoped app deploys are refused.
    if [[ "$s" == 'rails' || "$s" == 'sidekiq' ]]; then
      die "service-scoped app deploy is not allowed; rails and sidekiq always deploy together (only --service marine_sop_worker is permitted)"
    fi
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

# Resolve the deploy composition from the finalized TARGET_SERVICES. The app (rails+sidekiq) is
# the ONLY scope that carries a receipt + auto-rollback; the SOP worker keeps its existing
# receipt-less behavior. An app+SOP combined deploy is refused because an atomic cross-scope
# rollback is unsupported. --rollback is app-only and rejects SOP flags / --service selection.
APP_DEPLOY=0
SOP_ONLY_DEPLOY=0
resolve_composition() {
  local has_app=0 has_sop=0 s
  for s in "${TARGET_SERVICES[@]}"; do
    [[ "$s" == 'rails' || "$s" == 'sidekiq' ]] && has_app=1
    [[ "$s" == 'marine_sop_worker' ]] && has_sop=1
  done
  [[ "$MODE" == 'check' ]] && return 0
  if [[ "$MODE" == 'rollback' ]]; then
    [[ "$WITH_SOP" -eq 0 && "${#REQUESTED_SERVICES[@]}" -eq 0 ]] \
      || die "--rollback is app-only; --with-sop-worker and --service are not permitted"
  fi
  if [[ "$has_app" -eq 1 && "$has_sop" -eq 1 ]]; then
    die "combined app + SOP deploy is not supported (atomic cross-scope rollback is unavailable); deploy the app (rails+sidekiq) and the SOP worker (--service marine_sop_worker) in separate runs"
  elif [[ "$has_app" -eq 1 ]]; then
    APP_DEPLOY=1
  elif [[ "$has_sop" -eq 1 ]]; then
    SOP_ONLY_DEPLOY=1
  else
    die "no deployable services selected"
  fi
}
resolve_composition

# ---------------------------------------------------------------------------
# 0) Tooling + project/branch/remote validation.
# ---------------------------------------------------------------------------
validate_tools() {
  command -v "$DOCKER" >/dev/null 2>&1 || die "docker binary not found: $DOCKER"
  "$DOCKER" compose version >/dev/null 2>&1 || die "docker compose plugin not available"
  command -v jq >/dev/null 2>&1 || die "jq is required for config validation"
  command -v git >/dev/null 2>&1 || die "git is required"
  command -v python3 >/dev/null 2>&1 || die "python3 is required for the canonical receipt helper and the lifecycle lock"
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

# Exact commit authority for a forward deploy. Every git read here is of an ALREADY-EXISTING
# object/ref: no fetch and no ref mutation ever happen (the trusted remote tip is whatever the
# operator previously pulled into refs/remotes/origin/devbot). Freezes APP_EXPECTED_GIT_SHA.
validate_exact_commit_authority() {
  local head origin otype
  head="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "HEAD does not resolve to an exact 40-hex object"
  # cat-file -t (the object TYPE), never -e with ^{commit}: a tag/annotated object that merely
  # PEELS to a commit must be rejected — HEAD itself has to be exactly a commit.
  otype="$(git -C "$REPO_ROOT" cat-file -t "$head" 2>/dev/null || true)"
  [[ "$otype" == 'commit' ]] || die "HEAD object is not exactly a commit (got '${otype:-none}')"
  # NEW HEAD must equal the live trusted remote tip origin/devbot (read without any fetch) and be
  # a descendant-or-equal of that trusted history.
  origin="$(git -C "$REPO_ROOT" rev-parse --verify --quiet refs/remotes/origin/devbot 2>/dev/null || true)"
  [[ "$origin" =~ ^[0-9a-f]{40}$ ]] || die "trusted remote ref refs/remotes/origin/devbot is unavailable (no fetch performed)"
  [[ "$head" == "$origin" ]] || die "HEAD does not equal the live trusted remote tip origin/devbot"
  git -C "$REPO_ROOT" merge-base --is-ancestor "$origin" "$head" 2>/dev/null \
    || die "HEAD is not a descendant-or-equal of the trusted history origin/devbot"
  APP_EXPECTED_GIT_SHA="$head"
  ok "HEAD is an exact commit equal to the trusted tip origin/devbot (no fetch, no ref mutation)"
}

# ---------------------------------------------------------------------------
# 1) Preflight — fail BEFORE any compose `up`.
# ---------------------------------------------------------------------------
validate_overlay_files() {
  # The MANDATORY catalog overlay must be present in the file list and on disk.
  local seen=0 f
  for f in "${COMPOSE_ARGS[@]}"; do
    [[ "$f" == "$ACTIVE_CATALOG" ]] && seen=1
  done
  [[ "$seen" -eq 1 ]] || die "mandatory catalog overlay absent from compose file list"
  [[ -f "$ACTIVE_BASE" ]]    || die "base compose file is missing"
  [[ -s "$ACTIVE_CATALOG" ]] || die "mandatory catalog overlay is missing or empty"
  if [[ "$WITH_SOP" -eq 1 ]]; then
    [[ -s "$SOP_OVERLAY" ]] || die "SOP worker overlay is missing or empty"
    # The worker shares .env for app connectivity, so the overlay must explicitly
    # scrub the catalog password-file path inherited from that file and must not mount it.
    grep -qE "^[[:space:]]*-[[:space:]]*${CATALOG_ENV_KEY}=[[:space:]]*$" "$SOP_OVERLAY" \
      || die "SOP worker overlay must explicitly blank $CATALOG_ENV_KEY inherited from .env"
    if grep -q 'marine_catalog_ro_password' "$SOP_OVERLAY" 2>/dev/null; then
      die "SOP worker overlay must not mount the catalog secret"
    fi
    # Blocker 2: the runtime sandbox gate must be tracked in the repo, and the overlay
    # must never disable the child sandbox via the test-only opt-out.
    [[ -s "$SOP_SANDBOX_GATE" ]] || die "SOP sandbox runtime gate script is missing or empty"
    if grep -q 'MARINE_SOP_SANDBOX_TEST_ONLY' "$SOP_OVERLAY"; then
      die "SOP worker overlay must not set the sandbox test-only opt-out"
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

validate_sop_config_contract() {
  local json="$1" image app_image source base role overlay
  image="$(jq -r '.services["marine_sop_worker"].image // empty' <<<"$json")"
  app_image="$(jq -r '.services.rails.image // empty' <<<"$json")"
  source="$(jq -r --arg k "$SOP_SOURCE_LABEL" '.services["marine_sop_worker"].labels[$k] // empty' <<<"$json")"
  base="$(jq -r --arg k "$SOP_BASE_IMAGE_LABEL" '.services["marine_sop_worker"].labels[$k] // empty' <<<"$json")"
  role="$(jq -r --arg k "$SOP_ROLE_LABEL" '.services["marine_sop_worker"].labels[$k] // empty' <<<"$json")"
  overlay="$(jq -r --arg k "$SOP_OVERLAY_LABEL" '.services["marine_sop_worker"].labels[$k] // empty' <<<"$json")"

  [[ -n "$image" ]] || die "marine_sop_worker has no resolved dedicated image"
  [[ -n "$app_image" ]] || die "rails has no resolved image for SOP base provenance"
  [[ "$image" != "$app_image" ]] || die "marine_sop_worker must use a dedicated derivative image, not the app image"
  [[ "$source" =~ ^[0-9a-f]{40}$ ]] || die "marine_sop_worker source revision must be an exact full SHA"
  [[ "$base" == "$app_image" ]] || die "marine_sop_worker base-image label does not match the resolved app image"
  [[ "$role" == "$SOP_ROLE" ]] || die "marine_sop_worker role label is missing or invalid"
  [[ "$overlay" == "$SOP_OVERLAY_ID" ]] || die "marine_sop_worker overlay label is not the tracked SOP overlay"
  ok "marine_sop_worker resolved config has dedicated image + exact tracked provenance"
}

# Finding 2 — generic existence/env/secret validations that need NO compose render. Safe to run
# before asset materialization, so the forward app deploy renders Compose exactly once (afterwards).
preflight_static() {
  validate_overlay_files
}

# Finding 2 — render-dependent validations applied to the SINGLE resolved compose config passed in
# (never a re-render): valid JSON, the rails/sidekiq catalog service/mount contract, and (if the SOP
# worker is enabled) that it stays free of the catalog secret and carries its tracked provenance.
preflight_rendered() { # <resolved-json>
  local json="$1"
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
    validate_sop_config_contract "$json"
  fi
}

# Full single-render preflight used by --check and the SOP-only deploy (their established behavior).
preflight() {
  preflight_static
  preflight_rendered "$(resolve_config_json)"
}

# ---------------------------------------------------------------------------
# 2) Image safety — images must already exist locally (no build).
# ---------------------------------------------------------------------------
validate_sop_image_provenance_before_recreate() {
  local json="$1" image app_image expected_source expected_base image_id app_image_id image_source image_base image_role embedded_sha
  image="$(jq -r '.services["marine_sop_worker"].image // empty' <<<"$json")"
  app_image="$(jq -r '.services.rails.image // empty' <<<"$json")"
  expected_source="$(jq -r --arg k "$SOP_SOURCE_LABEL" '.services["marine_sop_worker"].labels[$k] // empty' <<<"$json")"
  expected_base="$(jq -r --arg k "$SOP_BASE_IMAGE_LABEL" '.services["marine_sop_worker"].labels[$k] // empty' <<<"$json")"
  image_id="$("$DOCKER" image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
  app_image_id="$("$DOCKER" image inspect --format '{{.Id}}' "$app_image" 2>/dev/null || true)"
  # OCI source/base/role labels are inspected from the EXACT resolved
  # immutable image ID ($image_id), never the mutable tag: after tag->ID
  # resolution a retagged/aliased image cannot smuggle provenance past this
  # gate.
  image_source="$("$DOCKER" image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image_id" 2>/dev/null || true)"
  image_base="$("$DOCKER" image inspect --format '{{ index .Config.Labels "com.wijaya.chatwoot.base-image" }}' "$image_id" 2>/dev/null || true)"
  image_role="$("$DOCKER" image inspect --format '{{ index .Config.Labels "com.wijaya.chatwoot.role" }}' "$image_id" 2>/dev/null || true)"

  [[ -n "$image_id" && -n "$app_image_id" ]] || die "SOP/app image identity could not be resolved before recreation"
  [[ "$image_id" != "$app_image_id" ]] || die "marine_sop_worker image resolves to the plain app image ID"
  [[ "$image_source" == "$expected_source" ]] || die "SOP image source label does not match resolved Compose provenance"
  [[ "$image_base" == "$expected_base" ]] || die "SOP image base label does not match resolved Compose provenance"
  [[ "$image_role" == "$SOP_ROLE" ]] || die "SOP image role label does not identify the dedicated worker"

  # Blocker 3: read /app/.git_sha from the EXACT resolved immutable image ID
  # (never the mutable tag) inside an ephemeral --network none container, and
  # require it to be nonempty and byte-identical to the expected full SHA. Only
  # then is the ID remembered as the verified ID later pinned for the
  # pre-image gate + compose up + post-runtime checks.
  embedded_sha="$("$DOCKER" run --rm --network none --entrypoint cat "$image_id" /app/.git_sha 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$embedded_sha" ]] || die "SOP derivative image embeds no readable /app/.git_sha (provenance binding failed)"
  [[ "$embedded_sha" == "$expected_source" ]] || die "SOP image embedded /app/.git_sha does not match the configured source revision"
  SOP_VERIFIED_IMAGE_ID="$image_id"
  ok "SOP derivative image identity + OCI labels + embedded .git_sha verified (immutable image ID bound)"
}

validate_images_present() {
  local json="$1" svc image
  for svc in "${TARGET_SERVICES[@]}"; do
    image="$(jq -r --arg s "$svc" '.services[$s].image // empty' <<<"$json")"
    [[ -n "$image" ]] || die "$svc has no resolved image (refusing to build)"
    "$DOCKER" image inspect "$image" >/dev/null 2>&1 || die "$svc image is not present locally (refusing to build)"
  done
  if [[ "$WITH_SOP" -eq 1 ]] && target_selected marine_sop_worker; then
    validate_sop_image_provenance_before_recreate "$json"
  fi
  ok "target service images present locally"
}

# G2: fail-closed app-image provenance gate. For each SELECTED request-serving
# service (rails, sidekiq) resolve its configured image to an immutable image ID
# ONCE and read /app/.git_sha from that EXACT ID (never the mutable tag again) in
# an ephemeral --network none container — the same safe preflight pattern the SOP
# provenance check uses. The embedded SHA must be nonempty and byte-identical to
# the expected 40-lowercase-hex target commit. Any missing / mismatched / unreadable
# SHA aborts BEFORE compose up. The verified ID is retained and then injected through
# the dedicated app-image Compose variable; the re-rendered config must resolve every
# selected app service to that exact ID, so recreation never dereferences the tag again.
validate_app_image_provenance_before_recreate() {
  local json="$1" svc image image_id embedded_sha selected=0
  APP_VERIFIED_IMAGE_ID=''
  [[ "$APP_EXPECTED_GIT_SHA" =~ ^[0-9a-f]{40}$ ]] \
    || die "app image provenance gate requires a resolvable repository HEAD with an exact 40-lowercase-hex SHA"
  for svc in rails sidekiq; do
    target_selected "$svc" || continue
    selected=1
    image="$(jq -r --arg s "$svc" '.services[$s].image // empty' <<<"$json")"
    [[ -n "$image" ]] || die "$svc has no resolved image for the app provenance gate"
    image_id="$("$DOCKER" image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
    [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || die "$svc app image identity could not be resolved to an immutable sha256 ID before recreation"
    if [[ -n "$APP_VERIFIED_IMAGE_ID" && "$image_id" != "$APP_VERIFIED_IMAGE_ID" ]]; then
      die "selected rails and sidekiq app images resolve to different immutable image IDs"
    fi
    # Append a non-newline sentinel before command substitution so Bash cannot
    # silently discard trailing newlines from the file. Accept exactly the image
    # build contract: 40 lowercase hex bytes followed by one newline.
    embedded_capture="$(
      "$DOCKER" run --rm --network none --entrypoint cat "$image_id" /app/.git_sha 2>/dev/null
      printf '\036%s' "$?"
    )"
    embedded_run_rc="${embedded_capture##*$'\036'}"
    embedded_raw="${embedded_capture%$'\036'*}"
    [[ "$embedded_run_rc" == '0' && -n "$embedded_raw" && "$embedded_raw" != $'\n' ]] \
      || die "$svc app image embeds no readable /app/.git_sha (provenance binding failed)"
    embedded_sha="${embedded_raw%$'\n'}"
    [[ "$embedded_raw" == "$embedded_sha"$'\n' && "$embedded_sha" =~ ^[0-9a-f]{40}$ ]] \
      || die "$svc app image embeds a malformed /app/.git_sha (expected exact 40-lowercase-hex plus one newline)"
    [[ "$embedded_sha" == "$APP_EXPECTED_GIT_SHA" ]] \
      || die "$svc app image embedded /app/.git_sha does not match the expected target SHA"
    APP_VERIFIED_IMAGE_ID="$image_id"
    ok "$svc app image embedded .git_sha verified against the target SHA (immutable image ID bound)"
  done
  [[ "$selected" -eq 0 || -n "$APP_VERIFIED_IMAGE_ID" ]] \
    || die "selected app services produced no verified immutable image ID"
}

# Finding 2 — transform the ONE already-rendered app Compose config IN MEMORY: pin rails+sidekiq to
# the verified immutable image ID and inject a stable, non-secret source-revision + config-hash
# label, all in a single jq pass. Compose assets are never reopened or re-rendered after the single
# render that produced <resolved-json>; the captured bytes are byte-for-byte the bytes fed to
# `compose up` on stdin (-f -). The captured bytes are then re-validated (image pin, provenance
# labels, AND the strict rails+sidekiq catalog service/mount contract) so exactly what recreation
# consumes is what was checked. Nothing here is persisted or printed (no resolved config, no secret
# values).
capture_app_compose_config() { # <source-sha> <resolved-json>
  local sha="$1" json="$2" img hash captured svc rendered rk hk
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "compose capture requires an exact 40-hex source commit"
  [[ -n "$json" ]] || die "cannot capture an empty resolved compose config"
  [[ "$APP_VERIFIED_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "compose capture requires a verified immutable app image ID"
  img="$APP_VERIFIED_IMAGE_ID"
  hash="$(compose_source_config_hash "$sha")"
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "could not compute the compose source config hash"
  rk="$COMPOSE_SOURCE_REVISION_LABEL"; hk="$COMPOSE_CONFIG_HASH_LABEL"
  captured="$(jq -c \
    --arg img "$img" --arg rk "$rk" --arg rv "$sha" --arg hk "$hk" --arg hv "$hash" '
        .services.rails.image   = $img | .services.sidekiq.image   = $img
      | .services.rails.labels[$rk]   = $rv | .services.rails.labels[$hk]   = $hv
      | .services.sidekiq.labels[$rk] = $rv | .services.sidekiq.labels[$hk] = $hv' <<<"$json")" \
    || die "failed to pin the app image and inject the compose provenance labels into the resolved config"
  [[ -n "$captured" ]] || die "captured compose config is empty after image pinning and label injection"
  # Re-prove, on the captured bytes, that both app services pin the verified immutable image and
  # carry the exact provenance labels — these are the bytes `compose up` will consume on stdin.
  for svc in rails sidekiq; do
    rendered="$(jq -r --arg s "$svc" '.services[$s].image // empty' <<<"$captured")"
    [[ "$rendered" == "$img" ]] \
      || die "$svc captured compose image is not the verified immutable app image ID"
    [[ "$(jq -r --arg s "$svc" --arg k "$rk" '.services[$s].labels[$k] // empty' <<<"$captured")" == "$sha" ]] \
      || die "$svc captured compose config is missing the source-revision label"
    [[ "$(jq -r --arg s "$svc" --arg k "$hk" '.services[$s].labels[$k] // empty' <<<"$captured")" == "$hash" ]] \
      || die "$svc captured compose config is missing the config-hash label"
  done
  # The captured bytes must also satisfy the strict rails+sidekiq catalog service/mount contract —
  # validating exactly what is fed to `compose up`, not only what the pre-capture render produced.
  validate_service_catalog_contract "$captured" 'rails'
  validate_service_catalog_contract "$captured" 'sidekiq'
  APP_CAPTURED_COMPOSE="$captured"
  ok "captured the resolved app compose config in memory (images pinned + source-revision/config-hash labels injected; catalog service/mount contract validated on the captured bytes; stdin-fed recreation)"
}

# ---------------------------------------------------------------------------
# 2b) Pre-image sandbox gate — must pass BEFORE any `compose up`.
# ---------------------------------------------------------------------------
# Blocker 2: the SAME tracked in-container gate script must pass inside an
# EPHEMERAL container (`docker run --rm --network none`) of the EXACT target
# SOP derivative image BEFORE any `compose up` recreates services. This proves
# the fail-closed sandbox contract of the image that is ABOUT to be deployed,
# not only the one already running. A failed pre-image gate aborts the deploy
# with ZERO `compose up` invocations (proven by the mocked deploy tests).
gate_sop_sandbox_pre_image() {
  local json="$1" image raw verdict
  [[ "$WITH_SOP" -eq 1 ]] || return 0
  target_selected marine_sop_worker || return 0
  image="$(jq -r '.services["marine_sop_worker"].image // empty' <<<"$json")"
  [[ -n "$image" ]] || die "marine_sop_worker has no resolved image for the pre-image sandbox gate"
  # Blocker 3: the gate must run the EXACT verified immutable image ID (the
  # pinned config never resolves the mutable tag again after verification).
  [[ -n "${SOP_VERIFIED_IMAGE_ID:-}" ]] || die "pre-image SOP sandbox gate requires the verified immutable image ID"
  [[ "$image" == "$SOP_VERIFIED_IMAGE_ID" ]] \
    || die "pre-image SOP sandbox gate is not bound to the verified immutable image ID"
  [[ -s "$SOP_SANDBOX_GATE" ]] || die "SOP sandbox gate script is missing or empty"
  # Blocker 2 fix: the image itself has NO /app/storage (the worker gets it only
  # from the storage_data volume at runtime), so the self-contained pre-image gate
  # mounts an ISOLATED EMPTY tmpfs at /app/storage — never the host/runtime
  # storage volume and never any customer data. The run mirrors the worker's
  # security contract needed by the gate (root canaries + su-exec workspace +
  # CAP_KILL over the dropped child): all caps dropped except
  # CHOWN/SETUID/SETGID/KILL, no-new-privileges, isolated tmpfs /tmp, and
  # pids/memory bounds. Still --network none, still the exact immutable image.
  raw="$("$DOCKER" run --rm --network none -i --entrypoint sh \
    --cap-drop ALL \
    --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add KILL \
    --security-opt no-new-privileges \
    --tmpfs /app/storage:rw,nosuid,nodev \
    --tmpfs /tmp:rw,nosuid,nodev,size=256m,mode=1777 \
    --pids-limit 256 --memory 2g \
    "$image" -s <"$SOP_SANDBOX_GATE" 2>/dev/null || true)"
  verdict="$(parse_sop_selftest_verdict "$raw")"
  [[ -n "$verdict" ]] || die "pre-image SOP sandbox gate emitted no sentinel"
  [[ "$verdict" == 'PASS' ]] || die "pre-image SOP sandbox gate failed on the exact target image (env allowlist / workspace isolation / decoy+symlink+socket denial / exec-target denial / real OCR parsers)"
  ok "marine_sop_worker pre-image sandbox gate PASSED (ephemeral --network none container of the exact target image, before compose up)"
}

# ---------------------------------------------------------------------------
# 3) Recreation — the ONLY mutating step.
# ---------------------------------------------------------------------------
recreate_services() {
  # Finding 2 — a receipt-backed app (rails+sidekiq) recreation feeds the captured, fully-resolved
  # compose config on stdin (-f -) so Compose consumes the EXACT validated bytes and can never
  # reopen a mutable asset path. --project-directory is the repo so the stdin recreation shares the
  # same project identity as the file-based `compose` used for ps/health resolution. A SOP-only
  # recreation (no captured config) keeps the file-based invocation.
  if [[ -n "$APP_CAPTURED_COMPOSE" ]]; then
    log "recreating from captured compose config (stdin): ${TARGET_SERVICES[*]}"
    printf '%s' "$APP_CAPTURED_COMPOSE" \
      | "$DOCKER" compose --project-directory "$REPO_ROOT" -f - up -d --no-deps --force-recreate --no-build "${TARGET_SERVICES[@]}" \
      || return $?
    ok "services recreated from the captured compose config (stdin)"
    return 0
  fi
  log "recreating: ${TARGET_SERVICES[*]}"
  compose up -d --no-deps --force-recreate --no-build "${TARGET_SERVICES[@]}" || return $?
  ok "services recreated"
}

# ---------------------------------------------------------------------------
# 4) Post-deploy health gate.
# ---------------------------------------------------------------------------
container_id() { compose ps -q "$1" 2>/dev/null; }

# Prove both app containers run the exact immutable image ID verified before recreation.
# Checking both rails and sidekiq (not only the selected service) rejects a mixed app runtime.
gate_app_runtime_image_identity() {
  [[ -n "${APP_VERIFIED_IMAGE_ID:-}" ]] || return 0
  local svc cid runtime_image
  for svc in rails sidekiq; do
    cid="$(container_id "$svc")"
    [[ -n "$cid" ]] || die "$svc container not running for app image identity gate"
    runtime_image="$("$DOCKER" inspect --format '{{.Image}}' "$cid" 2>/dev/null || true)"
    [[ "$runtime_image" == "$APP_VERIFIED_IMAGE_ID" ]]       || die "$svc runtime image ID does not match the verified immutable app image (mixed app images refused)"
  done
  ok "rails and sidekiq runtime image IDs match the verified immutable app image"
}

gate_config_files_label() {
  local cid labels
  # Finding 2 — the app (rails+sidekiq) is recreated from a stdin-fed config carrying NO
  # config_files path provenance; prove each app service's compose source from the injected Wijaya
  # labels instead (one-time historical config_files compatibility handled inside the proof). The
  # SOP worker keeps its file-based recreation and tracked-overlay config_files label.
  gate_app_compose_provenance
  if [[ "$WITH_SOP" -eq 1 ]]; then
    cid="$(container_id marine_sop_worker)"
    [[ -n "$cid" ]] || die "marine_sop_worker container not running after recreation"
    labels="$("$DOCKER" inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$cid" 2>/dev/null || true)"
    grep -qF "$ACTIVE_BASE" <<<"$labels" || die "marine_sop_worker config_files label is missing the base compose file"
    grep -qF "$ACTIVE_CATALOG" <<<"$labels" || die "marine_sop_worker config_files label is missing the mandatory catalog overlay"
    grep -qF "$SOP_OVERLAY" <<<"$labels" || die "marine_sop_worker config_files label is missing the current SOP overlay"
  fi
  ok "runtime app compose provenance proven (SOP worker, if any, carries the tracked overlays)"
}

# Finding 2 — prove one running app service's compose provenance and echo its proven 40-hex source
# commit. Preferred path: the injected Wijaya source-revision + config-hash labels — the revision
# must be an exact commit equal to the service's embedded runtime /app/.git_sha, and the config-hash
# must equal the hash recomputed from the trusted git blobs at that commit (never from a mutable
# asset). One-time historical compatibility: a service with NO Wijaya labels (a runtime created
# before the stdin scheme) is proven via its allowlisted config_files base+catalog pair against the
# trusted blobs. A new (labelled) runtime never depends on config_files. Prints nothing secret.
prove_app_service_compose_source() { # <svc> <cid> -> echoes 40-hex source sha
  local svc="$1" cid="$2" rev hash runtime_id runtime_sha want_hash label
  rev="$("$DOCKER" inspect --format '{{ index .Config.Labels "'"$COMPOSE_SOURCE_REVISION_LABEL"'" }}' "$cid" 2>/dev/null || true)"
  hash="$("$DOCKER" inspect --format '{{ index .Config.Labels "'"$COMPOSE_CONFIG_HASH_LABEL"'" }}' "$cid" 2>/dev/null || true)"
  runtime_id="$("$DOCKER" inspect --format '{{.Image}}' "$cid" 2>/dev/null || true)"
  runtime_sha="$(read_image_embedded_sha "$runtime_id" "$svc running app")"
  [[ "$(git -C "$REPO_ROOT" cat-file -t "$runtime_sha" 2>/dev/null || true)" == 'commit' ]] \
    || die "$svc running app embedded commit is not an exact commit object in this repository"
  if [[ -n "$rev" || -n "$hash" ]]; then
    [[ "$rev" == "$runtime_sha" ]] \
      || die "$svc compose-source-revision label does not match the embedded runtime commit"
    want_hash="$(compose_source_config_hash "$runtime_sha")"
    [[ "$hash" == "$want_hash" ]] \
      || die "$svc compose-config-sha256 label does not match the trusted compose blobs at the runtime commit"
    printf '%s' "$runtime_sha"
    return 0
  fi
  label="$("$DOCKER" inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$cid" 2>/dev/null || true)"
  _historical_config_files_proof "$svc" "$label" "$runtime_sha"
  printf '%s' "$runtime_sha"
}

# Historical (pre-stdin-scheme) proof for one app service's config_files label: it must be an
# allowlisted base+catalog pair whose on-disk bytes equal the trusted git blobs at <sha>.
_historical_config_files_proof() { # <who> <config_files-label> <sha>
  local who="$1" label="$2" sha="$3" entry kind base_path='' cat_path='' want_base want_cat
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    kind="$(_classify_config_file "$entry")"
    case "$kind" in
      base)    [[ -z "$base_path" ]] || die "$who references more than one base compose file"; base_path="$entry" ;;
      catalog) [[ -z "$cat_path" ]]  || die "$who references more than one catalog overlay"; cat_path="$entry" ;;
      *)       die "$who config_files references a non-allowlisted file: ${entry##*/}" ;;
    esac
  done < <(printf '%s\n' "$label" | tr ',' '\n')
  [[ -n "$base_path" && -n "$cat_path" ]] \
    || die "$who has neither the Wijaya compose provenance labels nor an allowlisted config_files base+catalog pair"
  want_base="$(git_blob_fingerprint "$sha" "$BASE_COMPOSE")"
  want_cat="$(git_blob_fingerprint "$sha" "$CATALOG_OVERLAY")"
  [[ -f "$base_path" ]] || die "$who base compose file is missing on disk: ${base_path##*/}"
  [[ -f "$cat_path" ]]  || die "$who catalog overlay is missing on disk: ${cat_path##*/}"
  [[ "$(sha256_of "$base_path")" == "$want_base" ]] \
    || die "$who base compose bytes do not equal the trusted blob at the running commit"
  [[ "$(sha256_of "$cat_path")" == "$want_cat" ]] \
    || die "$who catalog overlay bytes do not equal the trusted blob at the running commit"
}

# Finding 2 — prove BOTH app services' compose provenance after recreation and require their proven
# source revisions agree (a mixed app runtime is refused).
gate_app_compose_provenance() {
  local svc cid rails_src='' sidekiq_src='' src
  for svc in rails sidekiq; do
    cid="$(container_id "$svc")"
    [[ -n "$cid" ]] || die "$svc container not running for the compose provenance gate"
    src="$(prove_app_service_compose_source "$svc" "$cid")"
    if [[ "$svc" == 'rails' ]]; then rails_src="$src"; else sidekiq_src="$src"; fi
  done
  [[ "$rails_src" == "$sidekiq_src" ]] || die "rails and sidekiq compose source revisions disagree (mixed app runtime)"
  ok "rails and sidekiq compose provenance proven against the running commit"
}

gate_sop_runtime_provenance() {
  [[ "$WITH_SOP" -eq 1 ]] || return 0
  local json cid image expected_source expected_base container_image container_source container_base container_role container_overlay
  local runtime_sha image_source image_base image_role container_image_id resolved_image_id langs
  json="$(resolve_config_json)"
  cid="$(container_id marine_sop_worker)"
  [[ -n "$cid" ]] || die "marine_sop_worker container not running for provenance gate"
  image="$(jq -r '.services["marine_sop_worker"].image // empty' <<<"$json")"
  expected_source="$(jq -r --arg k "$SOP_SOURCE_LABEL" '.services["marine_sop_worker"].labels[$k] // empty' <<<"$json")"
  expected_base="$(jq -r --arg k "$SOP_BASE_IMAGE_LABEL" '.services["marine_sop_worker"].labels[$k] // empty' <<<"$json")"

  container_image="$("$DOCKER" inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
  container_source="$("$DOCKER" inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$cid" 2>/dev/null || true)"
  container_base="$("$DOCKER" inspect --format '{{ index .Config.Labels "com.wijaya.chatwoot.base-image" }}' "$cid" 2>/dev/null || true)"
  container_role="$("$DOCKER" inspect --format '{{ index .Config.Labels "com.wijaya.chatwoot.role" }}' "$cid" 2>/dev/null || true)"
  container_overlay="$("$DOCKER" inspect --format '{{ index .Config.Labels "com.wijaya.chatwoot.overlay" }}' "$cid" 2>/dev/null || true)"
  runtime_sha="$("$DOCKER" exec "$cid" cat /app/.git_sha 2>/dev/null | tr -d '[:space:]' || true)"
  image_source="$("$DOCKER" image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image" 2>/dev/null || true)"
  image_base="$("$DOCKER" image inspect --format '{{ index .Config.Labels "com.wijaya.chatwoot.base-image" }}' "$image" 2>/dev/null || true)"
  image_role="$("$DOCKER" image inspect --format '{{ index .Config.Labels "com.wijaya.chatwoot.role" }}' "$image" 2>/dev/null || true)"
  container_image_id="$("$DOCKER" inspect --format '{{.Image}}' "$cid" 2>/dev/null || true)"
  resolved_image_id="$("$DOCKER" image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"

  [[ "$container_image" == "$image" ]] || die "marine_sop_worker runtime image does not match resolved config"
  [[ -n "$resolved_image_id" && "$container_image_id" == "$resolved_image_id" ]] || die "marine_sop_worker runtime image ID does not match the pinned image"
  [[ "$runtime_sha" == "$expected_source" ]] || die "marine_sop_worker /app/.git_sha does not match configured source revision"
  [[ "$image_source" == "$expected_source" && "$container_source" == "$expected_source" ]] || die "marine_sop_worker source revision labels disagree"
  [[ "$image_base" == "$expected_base" && "$container_base" == "$expected_base" ]] || die "marine_sop_worker base-image provenance labels disagree"
  [[ "$image_role" == "$SOP_ROLE" && "$container_role" == "$SOP_ROLE" ]] || die "marine_sop_worker role provenance labels disagree"
  [[ "$container_overlay" == "$SOP_OVERLAY_ID" ]] || die "marine_sop_worker runtime overlay label is stale"

  "$DOCKER" exec "$cid" sh -lc \
    'for b in pdfinfo pdftotext pdftoppm pdfunite tesseract; do command -v "$b" >/dev/null || exit 1; done; command -v magick >/dev/null || command -v convert >/dev/null' \
    || die "marine_sop_worker is missing a required SOP processing binary"
  langs="$("$DOCKER" exec "$cid" tesseract --list-langs 2>/dev/null || true)"
  grep -qx 'eng' <<<"$langs" || die "marine_sop_worker is missing Tesseract eng data"
  grep -qx 'ind' <<<"$langs" || die "marine_sop_worker is missing Tesseract ind data"
  ok "marine_sop_worker runtime source/image/overlay provenance and SOP binaries agree"
}

# Blocker 2 — runtime sandbox gate: prove the fail-closed Landlock+seccomp contract
# inside the running worker. The tracked in-container script plants only synthetic
# randomized canaries (cleaned up on exit) and prints a single anchored verdict
# line; no paths, argv, env values or document content are ever surfaced. The
# same gate already had to pass PRE-IMAGE (gate_sop_sandbox_pre_image) before
# compose up; this post-start gate re-proves it inside the running container.
gate_sop_sandbox_contract() {
  [[ "$WITH_SOP" -eq 1 ]] || return 0
  local cid raw verdict
  cid="$(container_id marine_sop_worker)"
  [[ -n "$cid" ]] || die "marine_sop_worker container not running for sandbox gate"
  [[ -s "$SOP_SANDBOX_GATE" ]] || die "SOP sandbox runtime gate script is missing or empty"
  raw="$("$DOCKER" exec -i "$cid" sh -s <"$SOP_SANDBOX_GATE" 2>/dev/null || true)"
  verdict="$(parse_sop_selftest_verdict "$raw")"
  [[ -n "$verdict" ]] || die "SOP sandbox gate emitted no sentinel"
  [[ "$verdict" == 'PASS' ]] || die "SOP sandbox gate failed (env allowlist / workspace isolation / decoy+symlink+socket denial / exec-target denial / real OCR parsers)"
  ok "marine_sop_worker child sandbox verified (exact env allowlist, decoy+symlink+socket+exec-target denial, real Poppler/Tesseract ind+eng)"
}

# Blocker 2 — parent health gate: the worker itself must still reach PostgreSQL, Redis
# and the local ActiveStorage service (synthetic upload+delete probe with a RANDOMIZED
# SecureRandom.hex key; the synthetic key is ALWAYS deleted in a fail-safe ensure block
# and no key/path/content is ever printed). This is what justifies NOT isolating the
# parent container's network.
gate_sop_parent_health() {
  [[ "$WITH_SOP" -eq 1 ]] || return 0
  local cid raw verdict
  cid="$(container_id marine_sop_worker)"
  [[ -n "$cid" ]] || die "marine_sop_worker container not running for parent health gate"
  raw="$("$DOCKER" exec "$cid" bundle exec rails runner '
    m = "WIJAYA_SOP_PARENT"
    require "stringio"
    svc = nil
    key = nil
    begin
      ActiveRecord::Base.connection.execute("SELECT 1")          # PostgreSQL
      raise unless Sidekiq.redis { |r| r.ping } == "PONG"       # Redis
      require "securerandom"
      svc = ActiveStorage::Blob.service                          # local ActiveStorage RW
      key = "marine-sop-gate-probe-#{SecureRandom.hex(16)}"
      svc.upload(key, StringIO.new("gate"))
      svc.delete(key)
      key = nil
      puts "#{m}:PASS"
    rescue StandardError
      puts "#{m}:FAIL"
    ensure
      # Fail-safe cleanup: a synthetic probe key is ALWAYS deleted (idempotent when
      # absent); nothing about the key/path/content is ever printed.
      begin
        svc.delete(key) unless svc.nil? || key.nil?
      rescue StandardError
        nil
      end
    end' 2>/dev/null || true)"
  verdict="$(parse_sop_parent_verdict "$raw")"
  [[ -n "$verdict" ]] || die "SOP parent health gate emitted no sentinel"
  [[ "$verdict" == 'PASS' ]] || die "marine_sop_worker parent cannot reach PostgreSQL/Redis/ActiveStorage"
  ok "marine_sop_worker parent health verified (PostgreSQL + Redis + local ActiveStorage upload/delete)"
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

# --- Pure sentinel parsers (no docker; unit-tested by the regression suite) ---------
# Extract the SOP sandbox gate verdict: the in-container gate script prints exactly one
# anchored WIJAYA_SOP_GATE line (PASS or FAIL:<token>); everything else is ignored. Echoes
# 'PASS', 'FAIL' or '' when no sentinel line is present.
parse_sop_selftest_verdict() {
  local raw="$1" line
  line="$(grep -m1 -E '^WIJAYA_SOP_GATE:' <<<"$raw" | tr -d '\r' || true)"
  [[ -n "$line" ]] || { printf ''; return 0; }
  case "${line#WIJAYA_SOP_GATE:}" in
    PASS) printf 'PASS' ;;
    *)    printf 'FAIL' ;;
  esac
}

# Extract the SOP parent-health verdict (PostgreSQL + Redis + local ActiveStorage inside
# the marine_sop_worker container). Same anchored-line contract as above.
parse_sop_parent_verdict() {
  local raw="$1" line
  line="$(grep -m1 -E '^WIJAYA_SOP_PARENT:' <<<"$raw" | tr -d '\r' || true)"
  [[ -n "$line" ]] || { printf ''; return 0; }
  case "${line#WIJAYA_SOP_PARENT:}" in
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
  gate_app_runtime_image_identity
  gate_config_files_label
  target_selected marine_sop_worker && gate_sop_runtime_provenance
  target_selected marine_sop_worker && gate_sop_sandbox_contract
  target_selected marine_sop_worker && gate_sop_parent_health

  # A worker-only recreation must not be reported failed because an unrelated external
  # LLM/domain-boundary dependency is unhealthy. App behavior gates remain mandatory
  # whenever rails or normal sidekiq is one of the services changed by this deployment.
  if target_selected rails || target_selected sidekiq; then
    gate_password_file_and_mount
    gate_catalog_reference
    gate_domain_boundary_probe
    gate_deployment_window_logs "$since"
    gate_public_http
  else
    ok "app behavior gates not applicable to isolated SOP worker recreation"
  fi
  ok "post-deploy health gate PASSED"
}

sha256_of() { python3 "$RECEIPT_HELPER" sha256 "$1"; }

receipt_validate() { python3 "$RECEIPT_HELPER" validate 2>/dev/null; }

receipt_write() { python3 "$RECEIPT_HELPER" write; }

render_receipt_json() { # <target-sha> <app-id> <fp_base> <fp_catalog> <created_at>
  jq -cn \
    --argjson version "$RECEIPT_SCHEMA_VERSION" \
    --arg created "$5" --arg target "$1" --arg app "$2" \
    --arg fpb "$3" --arg fpc "$4" \
    '{ schema_version: $version, created_at: $created, target_git_sha: $target,
       app_image_id: $app, services: ["rails","sidekiq"],
       overlay_fingerprints: { base: $fpb, catalog: $fpc } }'
}

overlay_repo_relpath() {
  local abs="$1"
  case "$abs" in
    "$REPO_ROOT"/*) printf '%s' "${abs#"$REPO_ROOT"/}" ;;
    *) die "compose overlay is outside the repository (cannot bind to a git commit): ${abs##*/}" ;;
  esac
}

git_blob_fingerprint() { # <sha> <abs-overlay-path>
  local sha="$1" rel; rel="$(overlay_repo_relpath "$2")"
  git -C "$REPO_ROOT" cat-file -e "${sha}:${rel}" 2>/dev/null \
    || die "overlay '${rel}' is not tracked at commit ${sha}"
  git -C "$REPO_ROOT" show "${sha}:${rel}" 2>/dev/null | python3 "$RECEIPT_HELPER" sha256 -
}

# Finding 2 — stable, non-secret identity of the materialized compose SOURCE at <commit>: a hash
# binding the base + catalog overlay git-blob fingerprints at that commit. Recomputable at health
# time from the git blobs alone (never from a mutable asset path), so the injected runtime label can
# be validated without re-reading any mutable file.
compose_source_config_hash() { # <full-commit-sha>
  local sha="$1" fpb fpc
  fpb="$(git_blob_fingerprint "$sha" "$BASE_COMPOSE")"
  fpc="$(git_blob_fingerprint "$sha" "$CATALOG_OVERLAY")"
  printf '%s\n%s\n' "$fpb" "$fpc" | python3 "$RECEIPT_HELPER" sha256 -
}

# Finding 2 — durably + atomically materialize the base + mandatory catalog compose from the EXACT
# trusted commit into the persistent, immutable per-commit asset dir, hash-verify every byte, and
# repoint `compose` at those files with --project-directory the repo. Using persistent files (not
# temporary/deleted ones) keeps the containers' config_files labels valid for later verification,
# and using the materialized blobs for `compose up` closes the check-to-use gap: the bytes that
# were verified are byte-for-byte the bytes Compose consumes, regardless of the working tree.
materialize_commit_assets() { # <full-commit-sha>
  local sha="$1" baserel catrel want_base want_cat got_base got_cat
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "cannot materialize compose assets without an exact 40-hex commit"
  ensure_receipt_dir
  baserel="$(overlay_repo_relpath "$BASE_COMPOSE")"
  catrel="$(overlay_repo_relpath "$CATALOG_OVERLAY")"
  want_base="$(git_blob_fingerprint "$sha" "$BASE_COMPOSE")"
  want_cat="$(git_blob_fingerprint "$sha" "$CATALOG_OVERLAY")"
  got_base="$(git -C "$REPO_ROOT" show "${sha}:${baserel}" 2>/dev/null | python3 "$RECEIPT_HELPER" place-asset "$sha" "$ASSET_BASE_BASENAME")"
  got_cat="$(git -C "$REPO_ROOT" show "${sha}:${catrel}" 2>/dev/null | python3 "$RECEIPT_HELPER" place-asset "$sha" "$ASSET_CATALOG_BASENAME")"
  [[ "$got_base" == "$want_base" ]] || die "materialized base compose bytes do not match the git blob at ${sha}"
  [[ "$got_cat" == "$want_cat" ]] || die "materialized catalog overlay bytes do not match the git blob at ${sha}"
  ASSET_BASE="$RECEIPT_ASSETS_DIR/$sha/$ASSET_BASE_BASENAME"
  ASSET_CATALOG="$RECEIPT_ASSETS_DIR/$sha/$ASSET_CATALOG_BASENAME"
  # Prove the PERSISTED on-disk files equal the blob (closes materialize-to-use for the files
  # Compose will actually read).
  [[ -f "$ASSET_BASE" && "$(sha256_of "$ASSET_BASE")" == "$want_base" ]] \
    || die "persisted base compose asset drifted from the git blob at ${sha}"
  [[ -f "$ASSET_CATALOG" && "$(sha256_of "$ASSET_CATALOG")" == "$want_cat" ]] \
    || die "persisted catalog overlay asset drifted from the git blob at ${sha}"
  # Repoint Compose at the immutable persistent assets; relative paths resolve against the repo.
  ACTIVE_BASE="$ASSET_BASE"
  ACTIVE_CATALOG="$ASSET_CATALOG"
  COMPOSE_ARGS=(--project-directory "$REPO_ROOT" -f "$ASSET_BASE" -f "$ASSET_CATALOG")
  ok "materialized immutable compose assets for ${sha} (base+catalog, hash-verified, persistent, --project-directory repo)"
}

# Classify a config_files label entry by its fixed basename. Historical runtimes created the base
# as docker-compose.deploy.<shortsha>.yaml; that form is allowlisted as a base but still proven by
# bytes against the trusted blob below.
_classify_config_file() { # <path> -> base|catalog|other
  case "${1##*/}" in
    "$ASSET_BASE_BASENAME"|docker-compose.deploy.*.yaml) printf 'base' ;;
    "$ASSET_CATALOG_BASENAME")                           printf 'catalog' ;;
    *)                                                   printf 'other' ;;
  esac
}

# Finding 2 — prove the CURRENTLY-running app runtime's compose provenance before overwriting the
# rollback receipt. Reads BOTH rails and sidekiq config_files labels and requires they match each
# other; requires the label to be exactly one allowlisted base + one catalog (no stray files);
# and proves each referenced file's bytes equal the trusted git blob at the running image's
# embedded commit — so a historical docker-compose.deploy.<shortsha>.yaml base is accepted ONLY
# when its bytes equal that commit's blob.
gate_current_runtime_config_files() {
  local rails_cid sidekiq_cid rails_rev sidekiq_rev rails_label sidekiq_label runtime_id runtime_sha rails_src sidekiq_src
  rails_cid="$(container_id rails)"
  sidekiq_cid="$(container_id sidekiq)"
  [[ -n "$rails_cid" ]] || die "rails container not running for the current-runtime config_files proof"
  [[ -n "$sidekiq_cid" ]] || die "sidekiq container not running for the current-runtime config_files proof"
  rails_rev="$("$DOCKER" inspect --format '{{ index .Config.Labels "'"$COMPOSE_SOURCE_REVISION_LABEL"'" }}' "$rails_cid" 2>/dev/null || true)"
  sidekiq_rev="$("$DOCKER" inspect --format '{{ index .Config.Labels "'"$COMPOSE_SOURCE_REVISION_LABEL"'" }}' "$sidekiq_cid" 2>/dev/null || true)"
  # Finding 2 — steady state: the current runtime was created by a prior stdin-scheme deploy and
  # carries the Wijaya compose provenance labels. Prove each service from its labels and require the
  # two source revisions agree (mixed app runtime refused).
  if [[ -n "$rails_rev" || -n "$sidekiq_rev" ]]; then
    [[ -n "$rails_rev" && -n "$sidekiq_rev" ]] || die "rails and sidekiq config_files labels disagree (mixed app runtime)"
    rails_src="$(prove_app_service_compose_source rails "$rails_cid")"
    sidekiq_src="$(prove_app_service_compose_source sidekiq "$sidekiq_cid")"
    [[ "$rails_src" == "$sidekiq_src" ]] || die "rails and sidekiq config_files labels disagree (mixed app runtime)"
    ok "current runtime carries matching Wijaya compose provenance labels proven against the running commit"
    return 0
  fi
  # One-time historical compatibility: a runtime created before the stdin scheme carries config_files
  # path provenance. Require rails and sidekiq to reference the SAME allowlisted base+catalog pair
  # whose bytes equal the trusted blobs at the running (OLD) commit.
  rails_label="$("$DOCKER" inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$rails_cid" 2>/dev/null || true)"
  sidekiq_label="$("$DOCKER" inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$sidekiq_cid" 2>/dev/null || true)"
  [[ -n "$rails_label" ]] || die "rails config_files label is empty"
  [[ "$rails_label" == "$sidekiq_label" ]] || die "rails and sidekiq config_files labels disagree (mixed app runtime)"
  runtime_id="$(running_app_image_id)"
  runtime_sha="$(read_image_embedded_sha "$runtime_id" 'running app')"
  [[ "$(git -C "$REPO_ROOT" cat-file -t "$runtime_sha" 2>/dev/null || true)" == 'commit' ]] \
    || die "running app embedded commit is not an exact commit object in this repository"
  _historical_config_files_proof "current runtime" "$rails_label" "$runtime_sha"
  ok "current runtime config_files is an allowlisted base+catalog pair matching the blobs at the running commit"
}

read_image_embedded_sha() { # <image-id> <label>
  local image_id="$1" label="$2" capture run_rc raw sha
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "$label image is not an immutable sha256 image ID"
  capture="$(
    "$DOCKER" run --rm --network none --entrypoint cat "$image_id" /app/.git_sha 2>/dev/null
    printf '\036%s' "$?"
  )"
  run_rc="${capture##*$'\036'}"
  raw="${capture%$'\036'*}"
  [[ "$run_rc" == '0' && -n "$raw" && "$raw" != $'\n' ]] \
    || die "$label image embeds no readable /app/.git_sha (provenance binding failed)"
  sha="${raw%$'\n'}"
  [[ "$raw" == "$sha"$'\n' && "$sha" =~ ^[0-9a-f]{40}$ ]] \
    || die "$label image embeds a malformed /app/.git_sha (expected exact 40-lowercase-hex plus one newline)"
  printf '%s' "$sha"
}

assert_image_embeds_sha() {
  local image_id="$1" expected="$2" label="$3" sha
  sha="$(read_image_embedded_sha "$image_id" "$label")"
  [[ "$sha" == "$expected" ]] || die "$label image embedded /app/.git_sha does not match the rollback receipt"
}

ensure_receipt_dir() {
  python3 "$RECEIPT_HELPER" ensure >/dev/null 2>&1 || die "receipt directory or lifecycle lock is insecure"
}

running_app_image_id() {
  local svc cid runtime_id first_id=''
  for svc in rails sidekiq; do
    cid="$(container_id "$svc")"
    [[ -n "$cid" ]] || die "$svc container is not running (cannot capture the app runtime)"
    runtime_id="$("$DOCKER" inspect --format '{{.Image}}' "$cid" 2>/dev/null || true)"
    [[ "$runtime_id" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || die "$svc runtime image is not an immutable sha256 image ID"
    if [[ -z "$first_id" ]]; then first_id="$runtime_id"
    elif [[ "$runtime_id" != "$first_id" ]]; then
      die "running rails and sidekiq use different immutable image IDs (split app runtime)"
    fi
  done
  printf '%s' "$first_id"
}

prove_current_runtime_healthy() {
  gate_current_runtime_config_files
  gate_password_file_and_mount
  gate_catalog_reference
  gate_domain_boundary_probe
  gate_public_http
}

capture_app_receipt() {
  ensure_receipt_dir
  # Finding 2 — capture the running app image identity BEFORE the (slow) known-good health proof,
  # re-read it AFTER, and require it unchanged: the receipt must pin a runtime that did not move
  # out from under the proof.
  local id_before id_after app_id old_sha created json
  id_before="$(running_app_image_id)"
  ( prove_current_runtime_healthy ) \
    || die "current app runtime failed its known-good health proof; refusing to overwrite the rollback receipt. Recover with: custom/wijaya/deploy/deploy.sh --rollback"
  id_after="$(running_app_image_id)"
  [[ "$id_before" == "$id_after" ]] \
    || die "running app image ID changed during the known-good health proof (refusing to receipt a moving runtime)"
  app_id="$id_after"
  # Reject a no-op app deploy BEFORE any receipt write: if the running (OLD) runtime image ID is
  # already the exact verified NEW target, recreation would change nothing and overwriting the
  # receipt would discard the genuine pre-deploy known-good. The verified NEW ID is always known
  # here (set by validate_app_image_provenance_before_recreate before this capture).
  [[ "$APP_VERIFIED_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "cannot capture a receipt without a verified NEW app image ID"
  [[ "$app_id" != "$APP_VERIFIED_IMAGE_ID" ]] \
    || die "running app image ID already equals the verified target image ID; nothing to deploy (refusing to overwrite the rollback receipt with a no-op)"
  old_sha="$(read_image_embedded_sha "$app_id" 'running app')"
  [[ "$APP_EXPECTED_GIT_SHA" =~ ^[0-9a-f]{40}$ ]] || die "cannot capture a receipt without a resolvable repository HEAD commit"
  # Finding 3 — the captured OLD runtime commit must be real history: exactly a commit object and
  # an ancestor-or-equal of the trusted HEAD (which equals origin/devbot). Rejects pinning a
  # runtime whose embedded commit is not part of the deployed lineage.
  [[ "$(git -C "$REPO_ROOT" cat-file -t "$old_sha" 2>/dev/null || true)" == 'commit' ]] \
    || die "running app embedded commit is not an exact commit object in this repository"
  git -C "$REPO_ROOT" merge-base --is-ancestor "$old_sha" "$APP_EXPECTED_GIT_SHA" 2>/dev/null \
    || die "running app embedded commit is not an ancestor-or-equal of the deployed HEAD (origin/devbot)"
  # Finding 2 — the receipt's overlay fingerprints are the base/catalog blobs at the OLD runtime
  # commit: the exact bytes a rollback will re-materialize from that commit.
  RB_FP_BASE="$(git_blob_fingerprint "$old_sha" "$BASE_COMPOSE")"
  RB_FP_CATALOG="$(git_blob_fingerprint "$old_sha" "$CATALOG_OVERLAY")"
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  json="$(render_receipt_json "$old_sha" "$app_id" "$RB_FP_BASE" "$RB_FP_CATALOG" "$created")"
  [[ -n "$json" ]] || die "failed to render the deployment receipt"
  printf '%s' "$json" | receipt_write
  ok "recorded the app pre-deploy known-good rollback receipt (atomic, before recreation)"
}

recheck_forward_overlays() {
  local head
  head="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  [[ "$head" == "$APP_EXPECTED_GIT_SHA" ]] || die "repository HEAD changed during the deploy (refusing before compose up)"
  # The forward-deploy Compose input is the immutable materialized asset, not the working tree, so
  # this re-read just proves the persisted asset still equals the HEAD blob before compose up.
  [[ "$(sha256_of "$ASSET_BASE")" == "$(git_blob_fingerprint "$APP_EXPECTED_GIT_SHA" "$BASE_COMPOSE")" ]] \
    || die "materialized base compose asset changed before compose up (refusing)"
  [[ "$(sha256_of "$ASSET_CATALOG")" == "$(git_blob_fingerprint "$APP_EXPECTED_GIT_SHA" "$CATALOG_OVERLAY")" ]] \
    || die "materialized catalog overlay asset changed before compose up (refusing)"
}

load_rollback_receipt() { # <receipt-file>
  local line kv csv='' have
  line="$(receipt_validate)" || die "rollback receipt failed strict canonical validation: app.json"
  for kv in $line; do
    case "$kv" in
      target=*)     RB_TARGET_SHA="${kv#target=}" ;;
      app=*)        RB_APP_IMAGE_ID="${kv#app=}" ;;
      services=*)   csv="${kv#services=}" ;;
      fp_base=*)    RB_FP_BASE="${kv#fp_base=}" ;;
      fp_catalog=*) RB_FP_CATALOG="${kv#fp_catalog=}" ;;
    esac
  done
  IFS=',' read -ra RB_SERVICES <<<"$csv"
  have="$(printf '%s\n' "${RB_SERVICES[@]}" | sort | tr '\n' ',')"
  [[ "$have" == 'rails,sidekiq,' ]] || die "rollback receipt service set ($csv) is not the app pair rails,sidekiq"
  ok "rollback receipt validated"
}

assert_rollback_overlays_match() {
  # The rollback Compose input is the immutable asset materialized from the receipt's target
  # commit; prove its bytes equal the fingerprints the receipt recorded for that commit.
  [[ "$(sha256_of "$ASSET_BASE")" == "$RB_FP_BASE" ]] \
    || die "materialized base overlay bytes differ from the rollback receipt fingerprint (refusing)"
  [[ "$(sha256_of "$ASSET_CATALOG")" == "$RB_FP_CATALOG" ]] \
    || die "materialized catalog overlay bytes differ from the rollback receipt fingerprint (refusing)"
  ok "materialized base + catalog asset bytes match the rollback receipt fingerprints"
}

verify_rollback_image() {
  [[ -n "$RB_APP_IMAGE_ID" ]] || die "rollback receipt records no app image ID"
  "$DOCKER" image inspect "$RB_APP_IMAGE_ID" >/dev/null 2>&1 \
    || die "rollback app image is not present locally (refusing to build)"
  [[ "$("$DOCKER" image inspect --format '{{.Id}}' "$RB_APP_IMAGE_ID" 2>/dev/null)" == "$RB_APP_IMAGE_ID" ]] \
    || die "rollback app image ID did not resolve to itself"
  assert_image_embeds_sha "$RB_APP_IMAGE_ID" "$RB_TARGET_SHA" 'rollback app'
  ok "prior immutable app image present locally and still embeds the receipt SHA"
}

# Strict rollback preflight on the SINGLE rendered config (passed in, never re-rendered): mandatory
# overlays present + the rails/sidekiq catalog service/mount contract. The receipt-image identity is
# re-proven on the captured bytes (see capture_app_compose_config), which is exactly what recreation
# consumes.
rollback_preflight() { # <resolved-json>
  local json="$1"
  validate_overlay_files
  [[ -n "$json" ]] || die "resolved compose config is empty during rollback preflight"
  jq -e . >/dev/null 2>&1 <<<"$json" || die "resolved compose config is invalid during rollback preflight"
  validate_service_catalog_contract "$json" 'rails'
  validate_service_catalog_contract "$json" 'sidekiq'
  ok "strict rollback preflight passed (mandatory overlays, catalog contract)"
}

rollback_from_receipt() {
  local since st=0 json
  load_rollback_receipt
  # Finding 4 — an automatic rollback must target the OLD image, distinct from the NEW image just
  # attempted; otherwise there is nothing to roll back to.
  [[ -z "$ROLLBACK_DISTINCT_FROM" || "$RB_APP_IMAGE_ID" != "$ROLLBACK_DISTINCT_FROM" ]] \
    || die "rollback receipt image equals the NEW image just attempted (nothing to roll back to)"
  verify_rollback_image
  # Finding 2 — materialize the receipt's target-commit base+catalog into the persistent immutable
  # asset dir and roll back from THOSE files (--project-directory repo), so container config_files
  # labels stay valid and verifiable.
  materialize_commit_assets "$RB_TARGET_SHA"
  assert_rollback_overlays_match
  APP_VERIFIED_IMAGE_ID="$RB_APP_IMAGE_ID"
  # Finding 2 — render the rollback composition EXACTLY ONCE from the materialized receipt-commit
  # assets, then pin rails+sidekiq to the receipt image ID and inject provenance labels by
  # transforming those exact bytes in memory (jq, no re-render); `compose up` consumes the captured
  # bytes on stdin, so Compose never reopens a mutable asset.
  json="$(resolve_config_json)"
  rollback_preflight "$json"
  capture_app_compose_config "$RB_TARGET_SHA" "$json"
  since="$(date +%s)"
  recreate_services || st=$?
  [[ "$st" -eq 0 ]] || die "rollback compose up failed (status $st)"
  ok "services recreated from the rollback receipt (prior immutable app image ID pinned, no build)"
  health_gate "$since"
  ok "rollback runtime verification passed"
}

rollback_app() {
  ensure_receipt_dir
  [[ -e "$RECEIPT_FILE" || -L "$RECEIPT_FILE" ]] || die "no app rollback receipt available (nothing to roll back to)"
  rollback_from_receipt
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  # --check is non-mutating and never takes the lifecycle lock: validate tooling/project, run
  # preflight, and exit without reading or writing any receipt/runtime lifecycle state.
  if [[ "$MODE" == 'check' ]]; then
    validate_tools
    validate_project
    preflight
    ok "preflight-only (--check) complete; no services were recreated"
    exit 0
  fi

  # App mutation and rollback already re-exec'd under the fixed exclusive lifecycle lock at the
  # very TOP of this script (before any readiness/git/repo/project/tool/receipt/runtime read), and
  # the inherited locked fd was validated there. Re-prove it is present now that the mode is fully
  # resolved; --check and SOP-only deploy intentionally run lock-free.
  if [[ "$APP_DEPLOY" -eq 1 || "$MODE" == 'rollback' ]]; then
    [[ -n "$LIFECYCLE_LOCK_FD" ]] \
      || die "app deploy/rollback is not running under the validated lifecycle lock (ordering error)"
  fi
  validate_tools
  validate_project

  if [[ "$MODE" == 'rollback' ]]; then
    rollback_app
    ok "rollback complete"
    exit 0
  fi

  # --deploy. Resolve + prove the lifecycle's expected target HEAD only now that the lock is held.
  validate_exact_commit_authority

  local json since
  if [[ "$APP_DEPLOY" -eq 1 ]]; then
    # Finding 2 — the forward application deploy renders Compose EXACTLY ONCE, and only from the
    # trusted commit-keyed assets. Generic existence/env/secret validations that need no render run
    # first (on the working tree, before materialization); HEAD's immutable base+catalog are then
    # materialized and repointed into Compose, and the SINGLE `docker compose config` render is
    # taken from THOSE assets. Every render-dependent check (and the final contract checks in
    # capture_app_compose_config) runs on that one render / the in-memory captured bytes derived
    # from it — never on a second render of the mutable working tree.
    preflight_static
    materialize_commit_assets "$APP_EXPECTED_GIT_SHA"
    json="$(resolve_config_json)"
    preflight_rendered "$json"
  else
    # SOP-only deploy keeps its established preflight + resolve.
    preflight
    json="$(resolve_config_json)"
  fi
  validate_images_present "$json"

  # G2: verify the selected rails/sidekiq images embed the expected target commit at
  # /app/.git_sha (read from the resolved immutable image ID) BEFORE any recreate.
  validate_app_image_provenance_before_recreate "$json"
  if target_selected rails || target_selected sidekiq; then
    # Finding 2 — the config was rendered exactly ONCE above (from the materialized immutable
    # assets). Pin rails+sidekiq to the verified immutable image ID and inject provenance labels by
    # transforming those exact bytes in memory (no re-render); `compose up` consumes the captured
    # bytes on stdin, closing the asset check-to-use gap.
    capture_app_compose_config "$APP_EXPECTED_GIT_SHA" "$json"
  fi

  # Bind recreation to the EXACT verified immutable SOP image ID (exported, overriding any
  # operator tag) and re-resolve so the pre-image gate, compose up and post-runtime checks all
  # resolve the same immutable image content (no tag-retarget TOCTOU).
  if [[ "$WITH_SOP" -eq 1 ]] && target_selected marine_sop_worker; then
    [[ -n "${SOP_VERIFIED_IMAGE_ID:-}" ]] || die "SOP image ID was not verified before pinning"
    export MARINE_SOP_IMAGE="$SOP_VERIFIED_IMAGE_ID"
    ok "marine_sop_worker pinned to the verified immutable image ID for the pre-image gate + recreation"
    json="$(resolve_config_json)"
  fi

  gate_sop_sandbox_pre_image "$json"

  # SOP-only deploy keeps its existing receipt-less behavior: recreate + health gate, no receipt,
  # no auto-rollback. Only the app (rails+sidekiq) deploy is receipt-backed.
  if [[ "$SOP_ONLY_DEPLOY" -eq 1 ]]; then
    since="$(date +%s)"
    recreate_services
    health_gate "$since"
    ok "deploy complete"
    return 0
  fi

  # App deploy. Prove the CURRENT app runtime is known-good and record it as the rollback receipt
  # atomically — the immediate rollback authority — right BEFORE recreation. A prior crash that
  # left the runtime unhealthy refuses to overwrite the receipt, leaving the last known-good for
  # --rollback. Then recheck HEAD + overlay bytes one last time immediately before compose up.
  capture_app_receipt
  recheck_forward_overlays

  since="$(date +%s)"

  # Any recreation/health failure after the receipt is durable triggers exactly ONE automatic
  # rollback to the receipt (the pre-deploy known-good) and still exits with the ORIGINAL failure
  # status — even if the rollback itself fails. The rollback never triggers another rollback (no
  # lifecycle recursion), and the receipt is preserved unchanged for manual recovery.
  local deploy_status=0
  ( recreate_services ) || deploy_status=$?
  if [[ "$deploy_status" -eq 0 ]]; then
    ( health_gate "$since" ) || deploy_status=$?
  fi
  if [[ "$deploy_status" -ne 0 ]]; then
    log "deployment failed (status $deploy_status); attempting a single receipt-backed rollback to the app pre-deploy known-good"
    ROLLBACK_DISTINCT_FROM="$APP_VERIFIED_IMAGE_ID"
    if ( rollback_from_receipt ); then
      log "automatic rollback to the app pre-deploy known-good completed"
    else
      log "automatic rollback failed; manual intervention required (receipt retained: ${RECEIPT_FILE##*/})"
    fi
    exit "$deploy_status"
  fi
  ok "deploy complete"
}

# Run the pipeline unless sourced for unit testing (the regression suite sources this
# file with MARINE_DEPLOY_SOURCE_ONLY=1 to exercise the pure parsers / retry loop).
if [[ "${MARINE_DEPLOY_SOURCE_ONLY:-0}" != "1" ]]; then
  main
fi
