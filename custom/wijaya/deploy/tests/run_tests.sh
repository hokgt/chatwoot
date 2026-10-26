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
SOURCE_ROOT="$(git -C "$TESTS_DIR" rev-parse --show-toplevel 2>/dev/null || ( cd "$TESTS_DIR/../../../.." && pwd ))"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Every deploy/rollback invocation runs from a disposable repository COPY. The production script
# has no receipt-path override, and the fake docker cannot mutate a real Compose project.
REPO_ROOT="$WORK/repo"
mkdir -p "$REPO_ROOT/custom/wijaya/deploy/tests" \
  "$REPO_ROOT/custom/wijaya/scripts" \
  "$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy"
cp "$SOURCE_ROOT/custom/wijaya/deploy/deploy.sh" "$REPO_ROOT/custom/wijaya/deploy/deploy.sh"
cp "$SOURCE_ROOT/custom/wijaya/deploy/receipt.py" "$REPO_ROOT/custom/wijaya/deploy/receipt.py"
cp "$SOURCE_ROOT/custom/wijaya/scripts/marine_domain_boundary_monitor.sh" "$REPO_ROOT/custom/wijaya/scripts/marine_domain_boundary_monitor.sh"
cp "$SOURCE_ROOT/docker-compose.deploy.yaml" "$REPO_ROOT/docker-compose.deploy.yaml"
cp "$SOURCE_ROOT/custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-catalog.yml" \
  "$SOURCE_ROOT/custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-sop-worker.yml" \
  "$SOURCE_ROOT/custom/wijaya/batteries/marine_ai/deploy/sop_sandbox_gate.sh" \
  "$SOURCE_ROOT/custom/wijaya/batteries/marine_ai/deploy/wijaya_sop_sandbox.c" \
  "$SOURCE_ROOT/custom/wijaya/batteries/marine_ai/deploy/Dockerfile.sop-processing" \
  "$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/"
(
  cd "$REPO_ROOT"
  git init -q -b devbot
  git config user.email tests@example.invalid
  git config user.name deploy-tests
  git remote add origin git@github.com:hokgt/chatwoot.git
  # Two real commits: the first is the OLD pre-deploy ancestor, the second is the trusted HEAD.
  git add . && git commit -qm fixture-base
  git commit -q --allow-empty -m fixture-head
  # Materialize the trusted remote tracking tip WITHOUT any network fetch (disposable copy only),
  # so the exact-commit-authority gate can prove HEAD == origin/devbot.
  git update-ref refs/remotes/origin/devbot HEAD
)

DEPLOY_SH="$REPO_ROOT/custom/wijaya/deploy/deploy.sh"
RECEIPT_HELPER="$REPO_ROOT/custom/wijaya/deploy/receipt.py"
MONITOR_SH="$REPO_ROOT/custom/wijaya/scripts/marine_domain_boundary_monitor.sh"
CONTRACT_SH="$SOURCE_ROOT/custom/wijaya/scripts/check_deploy_contract.sh"
BASE_COMPOSE="$REPO_ROOT/docker-compose.deploy.yaml"
CATALOG_OVERLAY="$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-catalog.yml"
SOP_OVERLAY="$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-sop-worker.yml"
SOP_SANDBOX_GATE="$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/sop_sandbox_gate.sh"
SOP_SANDBOX_C="$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/wijaya_sop_sandbox.c"
SOP_DOCKERFILE="$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/Dockerfile.sop-processing"

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
      count=0
      if [[ -n "${FAKE_CONFIG_COUNT_FILE:-}" ]]; then
        count="$(cat "$FAKE_CONFIG_COUNT_FILE" 2>/dev/null || echo 0)"
        count=$((count+1)); printf '%s\n' "$count" >"$FAKE_CONFIG_COUNT_FILE"
      fi
      json="$(cat "${FAKE_CONFIG_JSON_FILE:?}")"
      # Finding 2 — the app (rails+sidekiq) image is pinned by deploy.sh IN the captured bytes via an
      # in-memory jq transform, NOT via Compose interpolation, so a render never pins the app image.
      # Only the SOP worker is still pinned through an exported interpolation variable.
      if [[ -n "${MARINE_SOP_IMAGE:-}" ]]; then
        json="$(jq --arg img "$MARINE_SOP_IMAGE" '.services["marine_sop_worker"].image = $img' <<<"$json")"
      fi
      # Finding 2 adversarial trap: when armed, a render at/after the given 1-based index returns a
      # RETARGETED app image. Armed BEYOND the single post-materialization render it must NEVER fire,
      # proving there is no post-verification re-render for an adversary to hijack.
      if [[ -n "${FAKE_RETARGET_ON_RENDER:-}" && "$count" -ge "$FAKE_RETARGET_ON_RENDER" ]]; then
        json="$(jq '.services.rails.image = "hokgt-chatwoot:retargeted-after-gate" | .services.sidekiq.image = "hokgt-chatwoot:retargeted-after-gate"' <<<"$json")"
      fi
      printf '%s\n' "$json"
      exit 0 ;;
    up)      : "${FAKE_UP_MARKER:?}"
              if [[ "${FAKE_REQUIRE_RECEIPT:-0}" == 1 && ! -f "${FAKE_RECEIPT_FILE:?}" ]]; then
                exit 91
              fi
              # Finding 2 — a receipt-backed app recreation feeds its fully-resolved config on stdin
              # (-f -). Read those captured bytes ONCE (they are the exact in-memory config deploy.sh
              # fed, so Compose never reopens a mutable asset path), then stash the injected Wijaya
              # provenance labels so a later `inspect` can echo them for the health gate.
              _stdin=0; for _a in "$@"; do [[ "$_a" == "-" ]] && _stdin=1; done
              _captured=""
              if [[ "$_stdin" == 1 ]]; then
                _captured="$(cat)"
                [[ -n "${FAKE_CAPTURED_COMPOSE_FILE:-}" ]] && printf '%s' "$_captured" >"$FAKE_CAPTURED_COMPOSE_FILE"
                # Adversarial seam: mutate a persistent asset at up-time (AFTER deploy captured its
                # config in memory). The captured bytes read above cannot change — proving the stdin
                # bytes, not the mutable asset path, are what Compose consumes.
                [[ -n "${FAKE_MUTATE_ASSET_BEFORE_UP:-}" ]] && printf '\n# mutated-at-up-time\n' >>"$FAKE_MUTATE_ASSET_BEFORE_UP"
              fi
              # Record the resolved -f overlay files so the config_files label inspect can echo
              # exactly what compose was invoked with. Only a FILE-based recreation (SOP worker)
              # carries asset paths; a stdin app recreation carries none.
              if [[ -n "${FAKE_CONFIG_FILES_FILE:-}" && "$_stdin" == 0 ]]; then
                : >"$FAKE_CONFIG_FILES_FILE"; _p=""
                for _a in "$@"; do
                  [[ "$_p" == "-f" ]] && printf '%s\n' "$_a" >>"$FAKE_CONFIG_FILES_FILE"
                  _p="$_a"
                done
              fi
              # Finding 2 — a stdin app recreation carries NO MARINE_DEPLOY_APP_IMAGE env (the image
              # is pinned IN the captured bytes via jq). Model the app image Compose will run from the
              # captured rails image; a file-based (SOP-only) recreation has no app image.
              _app_img=""
              if [[ "$_stdin" == 1 && -n "$_captured" ]]; then
                _app_img="$(jq -r '.services.rails.image // empty' <<<"$_captured" 2>/dev/null || true)"
              fi
              printf 'up MARINE_DEPLOY_APP_IMAGE=%s MARINE_SOP_IMAGE=%s MARINE_SOP_SOURCE_REVISION=%s argv=%s\n' \
                "$_app_img" "${MARINE_SOP_IMAGE:-}" "${MARINE_SOP_SOURCE_REVISION:-}" "$*" >>"$FAKE_UP_MARKER"
              # Model "running image == last deployed image": record the pinned ids so a later
              # `inspect {{.Image}}` reflects what this up recreated (lets post-up health gates and
              # rollback see the newly-running runtime).
              if [[ -n "${FAKE_RUNTIME_STATE_FILE:-}" ]]; then
                printf 'app=%s\nsop=%s\n' "$_app_img" "${MARINE_SOP_IMAGE:-}" >"$FAKE_RUNTIME_STATE_FILE"
                # Stash the injected Wijaya compose provenance labels (stdin recreation only) so the
                # new runtime models the stdin scheme for later inspect.
                if [[ "$_stdin" == 1 && -n "$_captured" ]]; then
                  _rev="$(jq -r '.services.rails.labels["com.wijaya.chatwoot.compose-source-revision"] // empty' <<<"$_captured" 2>/dev/null || true)"
                  _hash="$(jq -r '.services.rails.labels["com.wijaya.chatwoot.compose-config-sha256"] // empty' <<<"$_captured" 2>/dev/null || true)"
                  printf 'rev=%s\nhash=%s\n' "$_rev" "$_hash" >>"$FAKE_RUNTIME_STATE_FILE"
                fi
              fi
              # Optional seam: fail the FIRST compose up (crash model) so the deploy must
              # auto-roll-back once and preserve the original status; later rollback up succeeds.
              if [[ "${FAKE_UP_FAIL_FIRST:-0}" == 1 && "$(wc -l <"$FAKE_UP_MARKER")" == 1 ]]; then
                exit "${FAKE_UP_FAIL_STATUS:-42}"
              fi
              # Optional seam: fail the ROLLBACK (2nd) compose up so a rollback-compose failure can
              # be exercised; the original deploy status must still be preserved.
              if [[ "${FAKE_ROLLBACK_UP_FAIL:-0}" == 1 && "$(wc -l <"$FAKE_UP_MARKER")" == 2 ]]; then
                exit "${FAKE_ROLLBACK_UP_FAIL_STATUS:-55}"
              fi
              exit 0 ;;
    ps)      if [[ "${FAKE_PS_IDS:-0}" == "1" ]]; then
                svc="${args[${#args[@]}-1]}"
                if [[ ! -f "${FAKE_UP_MARKER:-/nonexistent}" && "$svc" == "${FAKE_MISSING_BEFORE_UP:-}" ]]; then
                  exit 0
                fi
                printf 'fake-%s\n' "$svc"
              fi
              exit 0 ;;
    *) exit 0 ;;
  esac
elif [[ "${1:-}" == "exec" ]]; then
  # Healthy-path sentinels so a deploy/rollback can be driven THROUGH the known-good capture
  # proof and the post-deploy health gate in tests: catalog-reference gate, domain-boundary
  # probe, catalog password-file probe, SOP child-sandbox gate, SOP parent-health probe, SOP
  # binaries/langs, and the SOP runtime /app/.git_sha read. A test can force an unhealthy
  # branch by overriding the relevant FAKE_* sentinel.
  case "$*" in
    *CatalogDomainReference*)   printf '%s\n' "${FAKE_CATALOG_GATE_OUT:-MARINE_CATALOG_GATE:PASS}" ;;
    *DomainBoundaryGuard*)
      # Fail the domain-boundary probe only when the compose-up count equals FAKE_PROBE_FAIL_ON_UPS
      # (1 = the forward post-up health gate; 2 = the rollback health gate). The pre-up known-good
      # proof runs at count 0 and stays healthy.
      _ups="$(wc -l <"${FAKE_UP_MARKER:-/nonexistent}" 2>/dev/null || echo 0)"; _ups="${_ups//[^0-9]/}"
      if [[ -n "${FAKE_PROBE_FAIL_ON_UPS:-}" && "${_ups:-0}" == "$FAKE_PROBE_FAIL_ON_UPS" ]]; then
        printf 'MARINE_PROBE:GREET=error UNREL=unrelated DCONV=0 DMSG=0 DRESP=0 ROLLBACK=1\n'
      else
        printf '%s\n' "${FAKE_PROBE_OUT:-MARINE_PROBE:GREET=allow UNREL=unrelated DCONV=0 DMSG=0 DRESP=0 ROLLBACK=1}"
      fi ;;
    *WIJAYA_SOP_PARENT*)        printf '%s\n' "${FAKE_SOP_PARENT_OUT:-WIJAYA_SOP_PARENT:PASS}" ;;
    *"tesseract --list-langs"*) printf 'eng\nind\n' ;;
    *" sh -s"*)                 printf '%s\n' "${FAKE_RUNTIME_SOP_GATE_OUT:-WIJAYA_SOP_GATE:PASS}" ;;
    *"/app/.git_sha"*)          printf '%s\n' "${FAKE_SOP_GIT_SHA:-}" ;;
    *printenv*)                 printf '%s\n' "${FAKE_CATALOG_ENV_PATH:-/run/secrets/marine_catalog_pg_password}" ;;
  esac
  exit 0
elif [[ "${1:-}" == "run" ]]; then
  # docker run invocations from deploy.sh: the embedded /app/.git_sha provenance
  # read (from the exact image ID) and the pre-image SOP sandbox gate. Both are
  # recorded (exact argv) so tests can prove which image ref was used; only the
  # configured embedded sha / gate verdict is ever emitted.
  : "${FAKE_RUN_MARKER:?}"
  printf '%s\n' "$*" >>"${FAKE_RUN_MARKER}"
  # Distinguish the app /app/.git_sha read (G2, from the resolved app image ID) from
  # the SOP read (from the SOP derivative image ID) by matching the exact image ID in
  # argv — proving each gate reads the immutable ID it resolved, not a shared tag.
  case "$*" in
    *"${FAKE_SOP_ID:-__nosopid__}"*'/app/.git_sha'*) printf '%s\n' "${FAKE_SOP_GIT_SHA:-}"; exit 0 ;;
    # A specific image id can embed a DRIFTED sha (distinct from the rest) so a rollback target
    # whose embedded .git_sha no longer matches its receipt can be exercised while the running
    # (reciprocal) image still reads a valid sha.
    *"${FAKE_DRIFT_IMAGE:-__nodrift__}"*'/app/.git_sha'*) printf '%s\n' "${FAKE_DRIFT_SHA:-}"; exit 0 ;;
    *'/app/.git_sha'*) printf '%s\n' "${FAKE_APP_GIT_SHA:-}"; exit 0 ;;
    *) printf '%s\n' "${FAKE_PRE_IMAGE_GATE_OUT:-WIJAYA_SOP_GATE:PASS}"; exit 0 ;;
  esac
elif [[ "${1:-}" == "inspect" ]]; then
  # Runtime inspects used by the health gate: runtime image identity, the config_files label
  # (echoed from the recorded -f overlay list), and the catalog mount read-only flag.
  fmt="${3:-}"; ref="${4:-}"
  st_app=""; st_sop=""; st_rev=""; st_hash=""
  if [[ -n "${FAKE_RUNTIME_STATE_FILE:-}" && -f "${FAKE_RUNTIME_STATE_FILE:-}" ]]; then
    st_app="$(sed -n 's/^app=//p' "$FAKE_RUNTIME_STATE_FILE")"
    st_sop="$(sed -n 's/^sop=//p' "$FAKE_RUNTIME_STATE_FILE")"
    st_rev="$(sed -n 's/^rev=//p' "$FAKE_RUNTIME_STATE_FILE")"
    st_hash="$(sed -n 's/^hash=//p' "$FAKE_RUNTIME_STATE_FILE")"
  fi
  case "$fmt" in
    '{{.Image}}')
      case "$ref" in
        fake-rails)             echo "${st_app:-${FAKE_RUNTIME_RAILS_IMAGE:-}}" ;;
        fake-sidekiq)           echo "${st_app:-${FAKE_RUNTIME_SIDEKIQ_IMAGE:-}}" ;;
        fake-marine_sop_worker) echo "${st_sop:-${FAKE_RUNTIME_SOP_IMAGE:-}}" ;;
      esac ;;
    '{{.Config.Image}}')
      case "$ref" in
        fake-rails|fake-sidekiq) echo "${MARINE_DEPLOY_APP_IMAGE:-${FAKE_APP_REF:-}}" ;;
        fake-marine_sop_worker) echo "${MARINE_SOP_IMAGE:-${FAKE_SOP_REF:-}}" ;;
      esac ;;
    *'com.wijaya.chatwoot.compose-source-revision'*)
      # Finding 2 — a stdin-scheme app runtime carries the injected source-revision label; model it
      # on rails/sidekiq only (SOP worker never carries it).
      case "$ref" in fake-rails|fake-sidekiq) printf '%s\n' "$st_rev" ;; *) true ;; esac ;;
    *'com.wijaya.chatwoot.compose-config-sha256'*)
      case "$ref" in fake-rails|fake-sidekiq) printf '%s\n' "$st_hash" ;; *) true ;; esac ;;
    *config_files*)
      # Finding 2 — a stdin app recreation carries NO config_files provenance (its rails/sidekiq
      # runtime proves provenance via the Wijaya labels above), so emit nothing for an app service
      # once the stdin scheme is in effect (st_rev set). Otherwise model the ALREADY-running runtime
      # per service: rails/sidekiq carry the base+catalog pair (FAKE_CURRENT_BASE_LABEL injects a
      # historical <shortsha> base path for the historical-label test); the SOP worker carries the
      # recorded file-based overlay list (base+catalog+SOP).
      case "$ref" in
        fake-rails)
          [[ -n "$st_rev" ]] || printf '%s\n%s\n' "${FAKE_CURRENT_BASE_LABEL:-${MARINE_DEPLOY_BASE_COMPOSE:-}}" "${MARINE_DEPLOY_CATALOG_OVERLAY:-}" ;;
        fake-sidekiq)
          [[ -n "$st_rev" ]] || printf '%s\n%s\n' "${FAKE_SIDEKIQ_CURRENT_BASE_LABEL:-${FAKE_CURRENT_BASE_LABEL:-${MARINE_DEPLOY_BASE_COMPOSE:-}}}" "${MARINE_DEPLOY_CATALOG_OVERLAY:-}" ;;
        *)
          if [[ -n "${FAKE_CONFIG_FILES_FILE:-}" && -s "${FAKE_CONFIG_FILES_FILE:-}" ]]; then
            cat "$FAKE_CONFIG_FILES_FILE"
          else
            printf '%s\n%s\n%s\n' "${MARINE_DEPLOY_BASE_COMPOSE:-}" "${MARINE_DEPLOY_CATALOG_OVERLAY:-}" "${MARINE_DEPLOY_SOP_OVERLAY:-}"
          fi ;;
      esac ;;
    # Current-SOP-provenance proof reads the running worker container's labels.
    *'org.opencontainers.image.revision'*) [[ "$ref" == fake-marine_sop_worker ]] && echo "${FAKE_RUNTIME_SOP_SOURCE:-}" || true ;;
    *'com.wijaya.chatwoot.base-image'*)    [[ "$ref" == fake-marine_sop_worker ]] && echo "${FAKE_RUNTIME_SOP_BASE:-}" || true ;;
    *'com.wijaya.chatwoot.role'*)          [[ "$ref" == fake-marine_sop_worker ]] && echo "${FAKE_RUNTIME_SOP_ROLE:-}" || true ;;
    *'com.wijaya.chatwoot.overlay'*)       [[ "$ref" == fake-marine_sop_worker ]] && echo "${FAKE_RUNTIME_SOP_OVERLAY:-}" || true ;;
    *Mounts*) echo "${FAKE_MOUNT_RW:-false}" ;;
  esac
  exit 0
elif [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  : "${FAKE_IMAGE_MARKER:?}"
  # A configured image can be simulated as absent locally (rollback must refuse to build).
  if [[ -n "${FAKE_ABSENT_IMAGE:-}" ]]; then
    for a in "$@"; do [[ "$a" == "$FAKE_ABSENT_IMAGE" ]] && exit 1; done
  fi
  if [[ "${3:-}" != "--format" ]]; then exit 0; fi
  fmt="${4:-}"; ref="${5:-}"
  # Record the exact resolved ref + format so tests can prove label inspects
  # dereference the immutable image ID after tag->ID resolution, never the
  # mutable tag.
  printf 'inspect ref=%s fmt=%s\n' "$ref" "$fmt" >>"$FAKE_IMAGE_MARKER"
  # Labels resolve identically from the mutable tag AND its resolved image ID.
  if [[ "$ref" == "${FAKE_SOP_REF:-}" || "$ref" == "${FAKE_SOP_ID:-}" ]]; then
    case "$fmt" in
      *'.Id'*) echo "${FAKE_SOP_ID:-}" ;;
      *'org.opencontainers.image.revision'*) echo "${FAKE_SOP_SOURCE:-}" ;;
      *'com.wijaya.chatwoot.base-image'*) echo "${FAKE_SOP_BASE:-}" ;;
      *'com.wijaya.chatwoot.role'*) echo "${FAKE_SOP_ROLE:-}" ;;
    esac
  elif [[ -n "${FAKE_RAILS_REF:-}" && "$ref" == "$FAKE_RAILS_REF" ]]; then
    case "$fmt" in *'.Id'*) echo "${FAKE_RAILS_ID:-}" ;; esac
  elif [[ -n "${FAKE_SIDEKIQ_REF:-}" && "$ref" == "$FAKE_SIDEKIQ_REF" ]]; then
    case "$fmt" in *'.Id'*) echo "${FAKE_SIDEKIQ_ID:-}" ;; esac
  elif [[ "$ref" == "${FAKE_APP_REF:-}" ]]; then
    case "$fmt" in *'.Id'*) echo "${FAKE_APP_ID:-}" ;; esac
  elif [[ "$ref" == sha256:* ]]; then
    # A bare immutable image ID resolves to itself (rollback re-verification inspects the
    # exact pinned prior ID, never a tag). Specific FAKE_* refs above still win. The running SOP
    # image ID also answers its provenance labels for the current-SOP-provenance proof.
    case "$fmt" in
      *'.Id'*) echo "$ref" ;;
      *'org.opencontainers.image.revision'*) [[ "$ref" == "${FAKE_RUNTIME_SOP_IMAGE:-}" ]] && echo "${FAKE_RUNTIME_SOP_SOURCE:-}" || true ;;
      *'com.wijaya.chatwoot.base-image'*)    [[ "$ref" == "${FAKE_RUNTIME_SOP_IMAGE:-}" ]] && echo "${FAKE_RUNTIME_SOP_BASE:-}" || true ;;
      *'com.wijaya.chatwoot.role'*)          [[ "$ref" == "${FAKE_RUNTIME_SOP_IMAGE:-}" ]] && echo "${FAKE_RUNTIME_SOP_ROLE:-}" || true ;;
    esac
  fi
  exit 0
fi
exit 0
FAKE
chmod +x "$FAKE_DOCKER"

# A fake curl that always reports HTTP 200, so the known-good capture proof + post-deploy health
# gate can be driven green without any real HTTP. (A "dead" variant is created later for the
# public-HTTP retry unit test.)
cat >"$WORK/curl_ok" <<'C'
#!/usr/bin/env bash
printf '200'; exit 0
C
chmod +x "$WORK/curl_ok"

# Valid 64-hex immutable image IDs for the running (pre-deploy) runtime captured by the receipt.
APP_RUNTIME_ID='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
SOP_RUNTIME_ID='sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'

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
grep -q "compose overlay is outside the repository (cannot bind to a git commit): dummy_overlay.yml" "$WORK/out.log" \
  && ok "dummy-overlay case is rejected because forward app assets must be commit-keyed" \
  || bad "dummy-overlay trusted-asset refusal message"

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

# SOP provenance fixtures use no secrets and exercise --check only.
make_sop_config() {
  local out="$1" image="$2" source="$3" base="$4" role="$5" overlay="$6"
  cat >"$out" <<JSON
{ "services": {
    "rails": {
      "image": "hokgt-chatwoot:test",
      "environment": { "MARINE_CATALOG_PG_PASSWORD_FILE": "/run/secrets/marine_catalog_pg_password" },
      "volumes": [ { "type": "bind", "source": "$SECRET_OK", "target": "/run/secrets/marine_catalog_pg_password", "read_only": true } ]
    },
    "sidekiq": {
      "image": "hokgt-chatwoot:test",
      "environment": { "MARINE_CATALOG_PG_PASSWORD_FILE": "/run/secrets/marine_catalog_pg_password" },
      "volumes": [ { "type": "bind", "source": "$SECRET_OK", "target": "/run/secrets/marine_catalog_pg_password", "read_only": true } ]
    },
    "marine_sop_worker": {
      "image": "$image", "environment": {}, "volumes": [],
      "labels": {
        "org.opencontainers.image.revision": "$source",
        "com.wijaya.chatwoot.base-image": "$base",
        "com.wijaya.chatwoot.role": "$role",
        "com.wijaya.chatwoot.overlay": "$overlay"
      }
    }
} }
JSON
}

run_deploy_sop_check() {
  local cfg="$1"
  CALLN=$((CALLN+1)); UP_MARKER="$WORK/up.$CALLN"; IMAGE_MARKER="$WORK/img.$CALLN"
  rm -f "$UP_MARKER" "$IMAGE_MARKER"; RC=0
  env DOCKER="$FAKE_DOCKER" MARINE_DEPLOY_BASE_COMPOSE="$BASE_COMPOSE" \
      MARINE_DEPLOY_CATALOG_OVERLAY="$CATALOG_OVERLAY" MARINE_DEPLOY_SOP_OVERLAY="$SOP_OVERLAY" \
      FAKE_CONFIG_JSON_FILE="$cfg" FAKE_UP_MARKER="$UP_MARKER" FAKE_IMAGE_MARKER="$IMAGE_MARKER" \
      bash "$DEPLOY_SH" --check --with-sop-worker >"$WORK/out.log" 2>&1 || RC=$?
}

FULL_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
SOP_OVERLAY_ID='custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-sop-worker.yml'
OLD_SOP_OVERLAY_ID='custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-'""'sop.yml'
CFG_SOP_OK="$WORK/cfg_sop_ok.json"
make_sop_config "$CFG_SOP_OK" 'chatwoot-wijaya:test-sop' "$FULL_SHA" 'hokgt-chatwoot:test' 'marine_sop_worker' "$SOP_OVERLAY_ID"
run_deploy_sop_check "$CFG_SOP_OK"
[[ "$RC" == 0 && ! -f "$UP_MARKER" ]] \
  && ok "SOP preflight accepts a dedicated image with exact source/base/overlay provenance" \
  || { bad "valid SOP provenance rejected (rc=$RC)"; cat "$WORK/out.log"; }

CFG_SOP_BASE="$WORK/cfg_sop_base.json"
make_sop_config "$CFG_SOP_BASE" 'hokgt-chatwoot:test' "$FULL_SHA" 'hokgt-chatwoot:test' 'marine_sop_worker' "$SOP_OVERLAY_ID"
run_deploy_sop_check "$CFG_SOP_BASE"
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'dedicated derivative image' "$WORK/out.log" \
  && ok "SOP preflight rejects worker accidentally using the base app image" \
  || { bad "base-image reuse was not rejected"; cat "$WORK/out.log"; }

CFG_SOP_OLD="$WORK/cfg_sop_old.json"
make_sop_config "$CFG_SOP_OLD" 'chatwoot-wijaya:test-sop' "$FULL_SHA" 'hokgt-chatwoot:test' 'marine_sop_worker' "$OLD_SOP_OVERLAY_ID"
run_deploy_sop_check "$CFG_SOP_OLD"
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'tracked SOP overlay' "$WORK/out.log" \
  && ok "SOP preflight rejects stale/retired overlay provenance" \
  || { bad "stale SOP overlay provenance was not rejected"; cat "$WORK/out.log"; }

CFG_SOP_SHA="$WORK/cfg_sop_sha.json"
make_sop_config "$CFG_SOP_SHA" 'chatwoot-wijaya:test-sop' 'short-sha' 'hokgt-chatwoot:test' 'marine_sop_worker' "$SOP_OVERLAY_ID"
run_deploy_sop_check "$CFG_SOP_SHA"
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'exact full SHA' "$WORK/out.log" \
  && ok "SOP preflight rejects a non-full source revision" \
  || { bad "short SOP source revision was not rejected"; cat "$WORK/out.log"; }

# Pre-image sandbox gate (Blocker 2): the tracked in-container gate must pass inside an
# ephemeral `docker run --rm --network none` container of the EXACT target SOP derivative
# image BEFORE any compose up. A FAILED gate must abort --deploy with ZERO compose up calls.
run_deploy_sop_deploy() { # <gate-output> <config-json> [<embedded-git-sha>]
  # ${3-...} (no colon): an explicitly EMPTY third arg stays empty; only a
  # missing one defaults to the correct full SHA.
  local gate_out="$1" cfg="$2" git_sha="${3-$FULL_SHA}"
  CALLN=$((CALLN+1)); UP_MARKER="$WORK/up.$CALLN"; IMAGE_MARKER="$WORK/img.$CALLN"
  RUN_MARKER="$WORK/run.$CALLN"
  rm -f "$UP_MARKER" "$IMAGE_MARKER" "$RUN_MARKER"
  RC=0
  env DOCKER="$FAKE_DOCKER" \
      MARINE_DEPLOY_BASE_COMPOSE="$BASE_COMPOSE" \
      MARINE_DEPLOY_CATALOG_OVERLAY="$CATALOG_OVERLAY" \
      MARINE_DEPLOY_SOP_OVERLAY="$SOP_OVERLAY" \
      FAKE_CONFIG_JSON_FILE="$cfg" FAKE_UP_MARKER="$UP_MARKER" FAKE_IMAGE_MARKER="$IMAGE_MARKER" \
      FAKE_RUN_MARKER="$RUN_MARKER" FAKE_PRE_IMAGE_GATE_OUT="$gate_out" \
      FAKE_SOP_REF='chatwoot-wijaya:test-sop' FAKE_APP_REF='hokgt-chatwoot:test' \
      FAKE_SOP_ID='sha256:sop' FAKE_APP_ID='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
      FAKE_SOP_SOURCE="$FULL_SHA" FAKE_SOP_BASE='hokgt-chatwoot:test' \
      FAKE_SOP_ROLE='marine_sop_worker' \
      FAKE_SOP_GIT_SHA="$git_sha" \
      FAKE_APP_GIT_SHA="$FULL_SHA" \
      FAKE_CONFIG_FILES_FILE="$WORK/cfgfiles.$CALLN" FAKE_RUNTIME_STATE_FILE="$WORK/sopstate.$CALLN" \
      FAKE_PS_IDS=1 FAKE_RUNTIME_RAILS_IMAGE="$APP_RUNTIME_ID" FAKE_RUNTIME_SIDEKIQ_IMAGE="$APP_RUNTIME_ID" \
      FAKE_RUNTIME_SOP_IMAGE="$SOP_RUNTIME_ID" FAKE_MOUNT_RW=false \
      FAKE_RUNTIME_SOP_SOURCE="$FULL_SHA" FAKE_RUNTIME_SOP_BASE='hokgt-chatwoot:test' \
      FAKE_RUNTIME_SOP_ROLE='marine_sop_worker' FAKE_RUNTIME_SOP_OVERLAY="$SOP_OVERLAY_ID" \
      MARINE_CURL="$WORK/curl_ok" "MARINE_MONITOR_LOG_CMD=printf ''" \
      bash "$DEPLOY_SH" --deploy --with-sop-worker --service marine_sop_worker >"$WORK/out.log" 2>&1 || RC=$?
}

run_deploy_sop_deploy 'WIJAYA_SOP_GATE:FAIL:pre-image' "$CFG_SOP_OK"
if [[ "$RC" != 0 && ! -f "$UP_MARKER" && -s "$RUN_MARKER" ]] && grep -q -- '--network none' "$RUN_MARKER"; then
  ok "failed pre-image SOP sandbox gate aborts --deploy with ZERO compose up calls (ephemeral --network none run)"
else
  bad "pre-image gate failure case (rc=$RC, up=$([[ -f "$UP_MARKER" ]] && echo yes || echo no), run=$([[ -s "$RUN_MARKER" ]] && echo yes || echo no))"; cat "$WORK/out.log"
fi

run_deploy_sop_deploy 'WIJAYA_SOP_GATE:PASS' "$CFG_SOP_OK"
if [[ -s "$RUN_MARKER" && -f "$UP_MARKER" ]]; then
  ok "passing pre-image SOP sandbox gate lets compose up proceed (gate ran before recreation)"
else
  bad "pre-image gate pass case (rc=$RC, run=$([[ -s "$RUN_MARKER" ]] && echo yes || echo no), up=$([[ -f "$UP_MARKER" ]] && echo yes || echo no))"; cat "$WORK/out.log"
fi

# Blocker 3 (final review) — embedded provenance binding + immutable image-ID pinning.
# The embedded /app/.git_sha must be read from the EXACT resolved image ID (never
# the mutable tag), the pre-image gate must run that same ID, and compose up must
# recreate with the SAME pinned ID (exported MARINE_SOP_IMAGE), so gate and
# recreation cannot diverge (no tag-retarget TOCTOU).
if grep -q -- '--entrypoint cat sha256:sop /app/.git_sha' "$RUN_MARKER" \
   && grep -qE -- '--network none -i --entrypoint sh .* sha256:sop -s' "$RUN_MARKER" \
   && ! grep -q -- 'chatwoot-wijaya:test-sop' "$RUN_MARKER"; then
  ok "embedded .git_sha read + pre-image gate both run the exact resolved image ID, never the mutable tag"
else
  bad "image-ID binding of the embedded read / pre-image gate (run marker: $(head -c 300 "$RUN_MARKER" 2>/dev/null))"
fi

# Pre-image gate isolation contract (Blocker 2 fix): the ephemeral gate container
# must be SELF-CONTAINED — /app/storage as an isolated EMPTY tmpfs (never the
# runtime storage_data volume or any host/customer data), isolated tmpfs /tmp,
# the worker's exact capability set, no-new-privileges, pids/memory bounds, and
# NO volume mounts at all — while still running the exact immutable image.
pre_gate_run="$(grep -- '--cap-drop ALL' "$RUN_MARKER" | head -1 || true)"
missing_flag=0
for f in '--cap-drop ALL' '--cap-add CHOWN' '--cap-add SETUID' '--cap-add SETGID' '--cap-add KILL' \
         '--security-opt no-new-privileges' \
         '--tmpfs /app/storage:rw,nosuid,nodev' \
         '--tmpfs /tmp:rw,nosuid,nodev,size=256m,mode=1777' \
         '--pids-limit 256' '--memory 2g'; do
  grep -qF -- "$f" <<<"$pre_gate_run" || missing_flag=1
done
if [[ "$missing_flag" == 0 ]] && ! grep -qE -- ' (-v |--volume |storage_data)' <<<"$pre_gate_run"; then
  ok "pre-image gate runs isolated: empty tmpfs /app/storage + tmpfs /tmp, cap_drop ALL + CHOWN/SETUID/SETGID/KILL, no-new-privileges, pids/mem bounds, no volume mounts"
else
  bad "pre-image gate isolation contract regressed (run: $(head -c 400 "$pre_gate_run" 2>/dev/null))"
fi
if grep -q 'MARINE_SOP_IMAGE=sha256:sop' "$UP_MARKER"; then
  ok "compose up recreates marine_sop_worker with the SAME verified immutable image ID (exported MARINE_SOP_IMAGE)"
else
  bad "compose up did not pin the verified immutable image ID (up marker: $(head -c 200 "$UP_MARKER" 2>/dev/null))"
fi

# Mismatched embedded .git_sha must block --deploy BEFORE any compose up.
run_deploy_sop_deploy 'WIJAYA_SOP_GATE:PASS' "$CFG_SOP_OK" '0000000000000000000000000000000000000000'
if [[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'embedded /app/.git_sha does not match' "$WORK/out.log"; then
  ok "mismatched embedded .git_sha blocks --deploy BEFORE compose up (image never reaches recreation)"
else
  bad "mismatched embedded .git_sha was not blocked (rc=$RC, up=$([[ -f "$UP_MARKER" ]] && echo yes || echo no))"; cat "$WORK/out.log"
fi

# An empty/unreadable embedded .git_sha must block the same way.
run_deploy_sop_deploy 'WIJAYA_SOP_GATE:PASS' "$CFG_SOP_OK" ''
if [[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'embeds no readable /app/.git_sha' "$WORK/out.log"; then
  ok "empty/absent embedded .git_sha blocks --deploy BEFORE compose up"
else
  bad "empty embedded .git_sha was not blocked (rc=$RC, up=$([[ -f "$UP_MARKER" ]] && echo yes || echo no))"; cat "$WORK/out.log"
fi

# Parent kill capability + child zero-capability contract (final review round).
if grep -q 'no-new-privileges:true' "$SOP_OVERLAY" && grep -qE '^[[:space:]]*- ALL$' "$SOP_OVERLAY"; then
  ok "SOP worker overlay keeps cap_drop ALL + no-new-privileges"
else
  bad "SOP overlay lost cap_drop ALL or no-new-privileges"
fi
cap_add_block="$(awk '/^    cap_add:/{f=1;next} f && /^    [a-z_]+:/{f=0} f && /^[[:space:]]*#/{next} f{print $2}' "$SOP_OVERLAY")"
[[ "$cap_add_block" == $'CHOWN\nSETUID\nSETGID\nKILL' ]] \
  && ok "SOP overlay grants the parent exactly CHOWN/SETUID/SETGID/KILL (KILL keeps the dropped-group reaper working)" \
  || bad "SOP overlay cap_add is not exactly CHOWN/SETUID/SETGID/KILL (got: $(printf '%s ' $cap_add_block))"
grep -q '__NR_capget' "$SOP_SANDBOX_C" && grep -q 'require_zero_capabilities();' "$SOP_SANDBOX_C" \
  && ok "launcher fail-closes on any nonzero effective/permitted capability (direct capget, no /proc reads)" \
  || bad "launcher missing the zero-capability capget check"
[[ "$(grep -c 'require_zero_capabilities();' "$SOP_SANDBOX_C")" == 2 ]] \
  && ok "zero-capability check runs in BOTH selftest and exec modes before any policy/exec" \
  || bad "zero-capability check call sites (expected 2, got $(grep -c 'require_zero_capabilities();' "$SOP_SANDBOX_C"))"
grep -q 'pgroup: true' "$SOP_SANDBOX_GATE" && grep -q 'kill-probe' "$SOP_SANDBOX_GATE" \
  && ok "sandbox gate proves parent CAP_KILL over a real su-exec-dropped marine_sop process group" \
  || bad "sandbox gate missing the parent-kill privilege-drop probe"
# The kill probe must WAIT on the private fd-3 readiness handshake (one fixed
# byte written only after the su-exec uid/gid drop) BEFORE any kill: no race
# between Process.spawn and Process.kill against a pre-drop child.
hs_line="$(grep -n 'IO.select' "$SOP_SANDBOX_GATE" | head -1 | cut -d: -f1 || true)"
kill_line="$(grep -n "Process.kill('-KILL', pid)" "$SOP_SANDBOX_GATE" | head -1 | cut -d: -f1 || true)"
if grep -q 'IO.pipe' "$SOP_SANDBOX_GATE" && grep -q '>&3' "$SOP_SANDBOX_GATE" \
   && grep -q 'exec /bin/sleep 30' "$SOP_SANDBOX_GATE" \
   && [[ -n "${hs_line:-}" && -n "${kill_line:-}" && "$hs_line" -lt "$kill_line" ]]; then
  ok "sandbox gate CAP_KILL probe waits on the private fd-3 post-drop readiness handshake BEFORE the kill (no pre-drop race)"
else
  bad "sandbox gate kill probe missing/after the readiness handshake (hs=$hs_line kill=$kill_line)"
fi
# The derivative Dockerfile must verify the embedded .git_sha BEFORE the labels.
sha_line="$(grep -n '/app/.git_sha' "$SOP_DOCKERFILE" | head -1 | cut -d: -f1 || true)"
label_line="$(grep -n '^LABEL ' "$SOP_DOCKERFILE" | head -1 | cut -d: -f1 || true)"
if [[ -n "$sha_line" && -n "$label_line" && "$sha_line" -lt "$label_line" ]]; then
  ok "Dockerfile.sop-processing fails the build unless embedded .git_sha equals the full SOURCE_REVISION, before labels"
else
  bad "Dockerfile embedded .git_sha verification ordering (sha=$sha_line label=$label_line)"
fi

# Static wiring: the pre-image gate must sit between image validation and recreate_services.
pre_gate_line="$(grep -n 'gate_sop_sandbox_pre_image "$json"' "$DEPLOY_SH" | head -1 | cut -d: -f1 || true)"
recreate_line="$(grep -nF '( recreate_services )' "$DEPLOY_SH" | head -1 | cut -d: -f1 || true)"
if [[ -n "${pre_gate_line:-}" && -n "${recreate_line:-}" && "$pre_gate_line" -lt "$recreate_line" ]]; then
  ok "pre-image SOP sandbox gate is wired BEFORE recreate_services (compose up) in main()"
else
  bad "pre-image SOP sandbox gate ordering in deploy.sh main()"
fi
grep -q 'run --rm --network none' "$DEPLOY_SH"   && ok "pre-image SOP sandbox gate uses an ephemeral --network none container of the target image"   || bad "pre-image SOP sandbox gate missing the --network none docker run"
# Static isolation contract: the pre-image gate in deploy.sh must keep the isolated
# tmpfs /app/storage (never a volume mount of runtime storage) and the worker's
# security contract; it must never gain a -v/--volume bind of /app/storage.
if grep -qF -- '--tmpfs /app/storage:rw,nosuid,nodev' "$DEPLOY_SH" \
   && grep -qF -- '--cap-drop ALL' "$DEPLOY_SH" \
   && grep -qF -- '--security-opt no-new-privileges' "$DEPLOY_SH" \
   && grep -qF -- '--pids-limit 256' "$DEPLOY_SH" \
   && ! grep -qE -- 'docker[^#]*run[^#]*(-v |--volume )' "$DEPLOY_SH"; then
  ok "deploy.sh pre-image gate statically keeps tmpfs /app/storage isolation + worker security contract, no volume mounts"
else
  bad "deploy.sh pre-image gate static isolation contract regressed"
fi
pin_line_static="$(grep -n 'export MARINE_SOP_IMAGE=' "$DEPLOY_SH" | head -1 | cut -d: -f1 || true)"
if [[ -n "${pin_line_static:-}" && "$pin_line_static" -lt "$pre_gate_line" && "$pre_gate_line" -lt "$recreate_line" ]]; then
  ok "verified image-ID pinning happens BEFORE the pre-image gate and compose up (no TOCTOU window)"
else
  bad "image-ID pin ordering in deploy.sh main() (pin=$pin_line_static gate=$pre_gate_line recreate=$recreate_line)"
fi

# Pre-recreation image identity gate: aliases of the plain app image must fail before up.
( export MARINE_DEPLOY_SOURCE_ONLY=1 DOCKER="$FAKE_DOCKER" FAKE_IMAGE_MARKER="$WORK/image-provenance"
  export FAKE_SOP_REF='chatwoot-wijaya:test-sop' FAKE_APP_REF='hokgt-chatwoot:test'
  export FAKE_SOP_ID='sha256:sop' FAKE_APP_ID='sha256:app' FAKE_SOP_SOURCE="$FULL_SHA"
  export FAKE_SOP_BASE='hokgt-chatwoot:test' FAKE_SOP_ROLE='marine_sop_worker'
  export FAKE_RUN_MARKER="$WORK/run-provenance" FAKE_SOP_GIT_SHA="$FULL_SHA"
  source "$DEPLOY_SH" --check --with-sop-worker --service marine_sop_worker >/dev/null 2>&1
  validate_sop_image_provenance_before_recreate "$(cat "$CFG_SOP_OK")"
) && ok "SOP image pre-recreation gate accepts distinct ID + matching OCI provenance" \
  || bad "valid SOP image identity/provenance rejected"
# Label inspects must dereference the EXACT resolved immutable image ID
# (sha256:sop) — never the mutable tag — after tag->ID resolution.
lbl_total="$(grep -c 'fmt=.*\.Config\.Labels' "$WORK/image-provenance" 2>/dev/null || true)"
lbl_id="$(grep 'fmt=.*\.Config\.Labels' "$WORK/image-provenance" 2>/dev/null | grep -c '^inspect ref=sha256:sop ' || true)"
lbl_tag="$(grep 'fmt=.*\.Config\.Labels' "$WORK/image-provenance" 2>/dev/null | grep -c '^inspect ref=chatwoot-wijaya:test-sop ' || true)"
if [[ "${lbl_total:-0}" == 3 && "${lbl_id:-0}" == 3 && "${lbl_tag:-0}" == 0 ]]; then
  ok "OCI/base/role label inspects resolve from the exact sha256:sop image ID, never the mutable tag"
else
  bad "label inspect ref binding (total=$lbl_total id=$lbl_id tag=$lbl_tag)"
fi

rc=0
( export MARINE_DEPLOY_SOURCE_ONLY=1 DOCKER="$FAKE_DOCKER" FAKE_IMAGE_MARKER="$WORK/image-alias"
  export FAKE_SOP_REF='chatwoot-wijaya:test-sop' FAKE_APP_REF='hokgt-chatwoot:test'
  export FAKE_SOP_ID='sha256:same' FAKE_APP_ID='sha256:same' FAKE_SOP_SOURCE="$FULL_SHA"
  export FAKE_SOP_BASE='hokgt-chatwoot:test' FAKE_SOP_ROLE='marine_sop_worker'
  export FAKE_RUN_MARKER="$WORK/run-alias" FAKE_SOP_GIT_SHA="$FULL_SHA"
  source "$DEPLOY_SH" --check --with-sop-worker --service marine_sop_worker >/dev/null 2>&1
  validate_sop_image_provenance_before_recreate "$(cat "$CFG_SOP_OK")" >"$WORK/image-alias.log" 2>&1
) || rc=$?
[[ "$rc" != 0 ]] && grep -q 'plain app image ID' "$WORK/image-alias.log" \
  && ok "SOP image pre-recreation gate rejects a different tag aliasing the app image ID" \
  || { bad "same-image-ID alias was not rejected before recreation"; cat "$WORK/image-alias.log"; }

# Target selection is exact: a worker-only deployment must not implicitly select the app.
( export MARINE_DEPLOY_SOURCE_ONLY=1
  source "$DEPLOY_SH" --check --with-sop-worker --service marine_sop_worker >/dev/null 2>&1
  target_selected marine_sop_worker || exit 51
  target_selected rails && exit 52
  target_selected sidekiq && exit 53
  exit 0
) && ok "worker-only target selection excludes rails and normal sidekiq" \
  || bad "worker-only target selection"

echo "== deploy.sh app-image provenance gate + immutable pin (G2) =="

APP_FULL_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
APP_IMAGE_ID='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
APP_IMAGE_ID_B='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
# A REAL ancestor commit (HEAD~1) so the forward deploy's OLD-runtime ancestry check is satisfied.
OLD_GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD~1)"

run_deploy_app() { # <embedded-sha> <default|rails|sidekiq> <config> [extra env...]
  local embedded="$1" target="$2" cfg="$3"; shift 3
  local deploy_args=(--deploy)
  case "$target" in
    default) ;;
    rails|sidekiq) deploy_args+=(--service "$target") ;;
    *) bad "invalid run_deploy_app target: $target"; return 1 ;;
  esac
  CALLN=$((CALLN+1)); UP_MARKER="$WORK/up.$CALLN"; IMAGE_MARKER="$WORK/img.$CALLN"; RUN_MARKER="$WORK/run.$CALLN"
  CONFIG_COUNT_FILE="$WORK/config-count.$CALLN"; CAPTURED="$WORK/captured.$CALLN"
  rm -f "$UP_MARKER" "$IMAGE_MARKER" "$RUN_MARKER" "$CONFIG_COUNT_FILE" "$CAPTURED"; RC=0
  env DOCKER="$FAKE_DOCKER" \
      MARINE_DEPLOY_BASE_COMPOSE="$BASE_COMPOSE" \
      MARINE_DEPLOY_CATALOG_OVERLAY="$CATALOG_OVERLAY" \
      MARINE_DEPLOY_SOP_OVERLAY="$SOP_OVERLAY" \
      FAKE_CONFIG_JSON_FILE="$cfg" FAKE_CONFIG_COUNT_FILE="$CONFIG_COUNT_FILE" \
      FAKE_CAPTURED_COMPOSE_FILE="$CAPTURED" \
      FAKE_UP_MARKER="$UP_MARKER" FAKE_IMAGE_MARKER="$IMAGE_MARKER" FAKE_RUN_MARKER="$RUN_MARKER" \
      FAKE_APP_REF='hokgt-chatwoot:test' FAKE_APP_ID="$APP_IMAGE_ID" FAKE_APP_GIT_SHA="$embedded" \
      FAKE_DRIFT_IMAGE="$APP_IMAGE_ID_B" FAKE_DRIFT_SHA="$OLD_GIT_SHA" \
      FAKE_CONFIG_FILES_FILE="$WORK/cfgfiles.$CALLN" FAKE_RUNTIME_STATE_FILE="$WORK/runstate.$CALLN" \
      FAKE_PS_IDS=1 FAKE_RUNTIME_RAILS_IMAGE="$APP_IMAGE_ID_B" FAKE_RUNTIME_SIDEKIQ_IMAGE="$APP_IMAGE_ID_B" \
      FAKE_MOUNT_RW=false MARINE_CURL="$WORK/curl_ok" "MARINE_MONITOR_LOG_CMD=printf ''" \
      "$@" bash "$DEPLOY_SH" "${deploy_args[@]}" >"$WORK/out.log" 2>&1 || RC=$?
}

# Default deployment: BOTH selected services are independently verified (2 embedded reads),
# the pre-deploy known-good is captured from the running runtime (1 more embedded read), then
# the verified immutable ID is pinned into the ONE rendered config IN MEMORY (jq, no re-render) and
# fed to fake compose up on stdin. A fully-healthy runtime drives it all the way to a successful
# (rc 0) deploy with ONE compose up.
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK"
# Finding 2 — the forward app lifecycle renders Compose EXACTLY ONCE total: the single
# post-materialization render (from the trusted commit-keyed assets) that is captured and pinned in
# memory. The pre-materialization preflight render is gone — generic existence/env/secret checks
# that need no render run before materialization, and the ONE render is the trusted post-materialize
# one. pin_app_image_for_recreate's second render is gone too.
renders="$(cat "$CONFIG_COUNT_FILE" 2>/dev/null || echo 0)"
# NEW target embedded sha reads: 2 pre-up (rails+sidekiq provenance gate) + 2 post-up (rails+sidekiq
# compose-provenance label gate binds the injected revision to the embedded runtime SHA) = 4.
app_reads="$(grep -c -- "--network none --entrypoint cat $APP_IMAGE_ID /app/.git_sha" "$RUN_MARKER" || true)"
# OLD runtime embedded sha is read twice: once for the current-runtime config_files blob proof,
# once to record it in the receipt.
old_reads="$(grep -c -- "--network none --entrypoint cat $APP_IMAGE_ID_B /app/.git_sha" "$RUN_MARKER" || true)"
up_count="$(grep -c 'MARINE_DEPLOY_APP_IMAGE=' "$UP_MARKER" 2>/dev/null || echo 0)"
APPJSON="$REPO_ROOT/custom/wijaya/deploy/.receipts/app.json"
ASSET_DIR="$REPO_ROOT/custom/wijaya/deploy/.receipts/assets/$APP_FULL_SHA"
ASSET_BASE_F="$ASSET_DIR/docker-compose.deploy.yaml"
ASSET_CAT_F="$ASSET_DIR/docker-compose.marine-catalog.yml"
DEF_CAPTURED="$WORK/captured.$CALLN"
if [[ "$RC" == 0 && "$app_reads" == 4 && "$old_reads" == 2 && "$up_count" == 1 ]] \
   && [[ "$(jq -r '.app_image_id' "$APPJSON")" == "$APP_IMAGE_ID_B" ]] \
   && [[ "$(jq -r '.target_git_sha' "$APPJSON")" == "$OLD_GIT_SHA" ]] \
   && grep -q "MARINE_DEPLOY_APP_IMAGE=$APP_IMAGE_ID" "$UP_MARKER" \
   && grep -qF -- '--project-directory' "$UP_MARKER" \
   && grep -qF -- '-f - up' "$UP_MARKER" \
   && [[ -f "$ASSET_BASE_F" && -f "$ASSET_CAT_F" ]] \
   && [[ -s "$DEF_CAPTURED" ]] \
   && [[ "$(jq -r '.services.rails.image' "$DEF_CAPTURED")" == "$APP_IMAGE_ID" ]] \
   && [[ "$(jq -r '.services.sidekiq.image' "$DEF_CAPTURED")" == "$APP_IMAGE_ID" ]] \
   && [[ "$(jq -r '.services.rails.labels["com.wijaya.chatwoot.compose-source-revision"]' "$DEF_CAPTURED")" == "$APP_FULL_SHA" ]] \
   && [[ "$(jq -r '.services.rails.environment["MARINE_CATALOG_PG_PASSWORD_FILE"]' "$DEF_CAPTURED")" == "/run/secrets/marine_catalog_pg_password" ]] \
   && [[ "$(jq -r '.services.rails.volumes[0].read_only' "$DEF_CAPTURED")" == "true" ]] \
   && [[ "$(jq -r '.services.sidekiq.volumes[0].read_only' "$DEF_CAPTURED")" == "true" ]] \
   && [[ "$renders" == 1 ]] \
   && grep -q 'catalog service/mount contract validated on the captured bytes' "$WORK/out.log"; then
  ok "app deploy renders Compose exactly once (after materialization), verifies NEW target, receipts OLD before up, pins+validates the captured bytes (image + catalog mount/service) in memory, and recreates the pair on stdin (-f -, --project-directory repo)"
else
  bad "default app pin case (rc=$RC new_reads=$app_reads old_reads=$old_reads up_count=$up_count renders=$renders)"; cat "$WORK/out.log"
fi

# Changed-after-materialization cannot alter the Compose input: the persistent HEAD assets are
# immutable (O_EXCL place-asset), and compose up consumed those exact files — so editing the
# working-tree overlays afterward can never change what was deployed. Prove the asset bytes equal
# the HEAD blob regardless of a subsequent working-tree edit.
printf '\n# tampered-after-deploy\n' >>"$CATALOG_OVERLAY"
blob_cat="$(git -C "$REPO_ROOT" show "$APP_FULL_SHA:custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-catalog.yml" | sha256sum | cut -d' ' -f1)"
asset_cat="$(sha256sum "$ASSET_CAT_F" | cut -d' ' -f1)"
[[ "$asset_cat" == "$blob_cat" && "$asset_cat" != "$(sha256sum "$CATALOG_OVERLAY" | cut -d' ' -f1)" ]] \
  && ok "materialized asset is immutable: a post-deploy working-tree edit does not change the deployed Compose input" \
  || bad "materialized asset immutability (asset=$asset_cat blob=$blob_cat)"
git -C "$REPO_ROOT" checkout -q -- custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-catalog.yml

# Finding 2 — mutate the mutable WORKING TREE BEFORE/AROUND materialization and prove it cannot
# affect the single trusted render: the forward app deploy materializes (and renders from) only the
# commit-keyed asset taken from the HEAD git blob, so a working-tree edit present during the deploy
# never reaches the materialized asset or the captured config fed to compose up.
rm -rf "$REPO_ROOT/custom/wijaya/deploy/.receipts"
# Model the already-running OLD runtime with stdin-era provenance labels, so its health proof is
# bound to trusted git blobs rather than the mutable working-tree config_files fallback.
wt_old_base_fp="$(git -C "$REPO_ROOT" show "$OLD_GIT_SHA:docker-compose.deploy.yaml" | sha256sum | cut -d' ' -f1)"
wt_old_cat_fp="$(git -C "$REPO_ROOT" show "$OLD_GIT_SHA:custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-catalog.yml" | sha256sum | cut -d' ' -f1)"
wt_old_config_hash="$(printf '%s\n%s\n' "$wt_old_base_fp" "$wt_old_cat_fp" | sha256sum | cut -d' ' -f1)"
WT_RUNTIME_STATE="$WORK/wt-runtime-state"
printf 'app=%s\nrev=%s\nhash=%s\n' "$APP_IMAGE_ID_B" "$OLD_GIT_SHA" "$wt_old_config_hash" >"$WT_RUNTIME_STATE"
printf '\n# working-tree-poison-before-materialize\n' >>"$CATALOG_OVERLAY"
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" FAKE_RUNTIME_STATE_FILE="$WT_RUNTIME_STATE"
WT_CAPTURED="$WORK/captured.$CALLN"
WT_ASSET="$REPO_ROOT/custom/wijaya/deploy/.receipts/assets/$APP_FULL_SHA/docker-compose.marine-catalog.yml"
wt_blob_cat="$(git -C "$REPO_ROOT" show "$APP_FULL_SHA:custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-catalog.yml" | sha256sum | cut -d' ' -f1)"
git -C "$REPO_ROOT" checkout -q -- custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-catalog.yml
if [[ "$RC" == 0 && -s "$WT_CAPTURED" && -f "$WT_ASSET" ]] \
   && [[ "$(sha256sum "$WT_ASSET" | cut -d' ' -f1)" == "$wt_blob_cat" ]] \
   && ! grep -q 'working-tree-poison-before-materialize' "$WT_ASSET" \
   && ! grep -q 'working-tree-poison-before-materialize' "$WT_CAPTURED"; then
  ok "a working-tree edit present before/around materialization never reaches the materialized asset or the captured config (render is only from the commit-keyed blob)"
else
  bad "working-tree poison before materialization leaked (rc=$RC)"; cat "$WORK/out.log"
fi
rm -rf "$REPO_ROOT/custom/wijaya/deploy/.receipts"

# Finding 2 adversarial (check-to-use): mutate the PERSISTENT asset AFTER config capture but BEFORE
# compose up, and prove the EXACT captured bytes are fed on stdin — Compose never reopens the mutable
# asset path. The fake up (which runs only after deploy.sh has captured its config in memory)
# appends a marker to the materialized catalog asset, then records the stdin it received. The
# recorded stdin must NOT contain the marker (captured before the mutation) while the asset on disk
# MUST (it was mutated), and up must have used -f -. Health still passes (rc 0) because the custom
# labels are validated against the trusted git blobs, never the mutated asset.
rm -rf "$REPO_ROOT/custom/wijaya/deploy/.receipts"
MUT_ASSET="$REPO_ROOT/custom/wijaya/deploy/.receipts/assets/$APP_FULL_SHA/docker-compose.marine-catalog.yml"
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" FAKE_MUTATE_ASSET_BEFORE_UP="$MUT_ASSET"
MUT_CAPTURED="$WORK/captured.$CALLN"
if [[ "$RC" == 0 && -s "$MUT_CAPTURED" ]] \
   && grep -qF -- '-f - up' "$UP_MARKER" \
   && [[ "$(jq -r '.services.rails.image' "$MUT_CAPTURED")" == "$APP_IMAGE_ID" ]] \
   && ! grep -q 'mutated-at-up-time' "$MUT_CAPTURED" \
   && grep -q 'mutated-at-up-time' "$MUT_ASSET"; then
  ok "compose up consumes the EXACT captured config via stdin; a post-capture asset mutation cannot change what is deployed"
else
  bad "stdin captured-config adversarial case (rc=$RC captured=$([[ -s "$MUT_CAPTURED" ]] && echo yes || echo no))"; cat "$WORK/out.log"
fi
rm -rf "$REPO_ROOT/custom/wijaya/deploy/.receipts"

# Same-ID refusal: if the running (OLD) runtime already IS the verified NEW target image, the
# deploy is a no-op and MUST be refused BEFORE any receipt write and BEFORE any compose up — so
# the genuine pre-deploy known-good receipt is never overwritten with a reciprocal no-op.
rm -rf "$REPO_ROOT/custom/wijaya/deploy/.receipts"
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" \
  FAKE_RUNTIME_RAILS_IMAGE="$APP_IMAGE_ID" FAKE_RUNTIME_SIDEKIQ_IMAGE="$APP_IMAGE_ID"
if [[ "$RC" != 0 && ! -f "$UP_MARKER" && ! -f "$APPJSON" ]] \
   && grep -q 'already equals the verified target image ID' "$WORK/out.log"; then
  ok "no-op deploy (running image already equals NEW target) is refused before receipt write and before up"
else
  bad "same-ID refusal case (rc=$RC up=$([[ -f "$UP_MARKER" ]] && echo yes || echo no) receipt=$([[ -f "$APPJSON" ]] && echo yes || echo no))"; cat "$WORK/out.log"
fi

# Exact-commit authority negatives (Finding 3). All git reads are of pre-existing refs/objects;
# the fixture only ever LOCALLY updates its disposable copy's tracking ref (never a fetch).
# (a) HEAD must equal the live trusted tip origin/devbot.
git -C "$REPO_ROOT" update-ref refs/remotes/origin/devbot "$OLD_GIT_SHA"
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK"
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'does not equal the live trusted remote tip' "$WORK/out.log" \
  && ok "HEAD not equal to the trusted tip origin/devbot fails before any up" \
  || { bad "trusted-tip mismatch case (rc=$RC)"; cat "$WORK/out.log"; }
# (b) The trusted ref must be present (no fetch is ever performed to create it).
git -C "$REPO_ROOT" update-ref -d refs/remotes/origin/devbot
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK"
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'trusted remote ref refs/remotes/origin/devbot is unavailable' "$WORK/out.log" \
  && ok "missing trusted remote ref fails closed (deploy never fetches)" \
  || { bad "missing trusted ref case (rc=$RC)"; cat "$WORK/out.log"; }
git -C "$REPO_ROOT" update-ref refs/remotes/origin/devbot HEAD   # restore trusted tip == HEAD
# (c) The captured OLD runtime commit must be real ancestor history, not an arbitrary 40-hex.
rm -rf "$REPO_ROOT/custom/wijaya/deploy/.receipts"
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" FAKE_DRIFT_SHA='dddddddddddddddddddddddddddddddddddddddd'
[[ "$RC" != 0 && ! -f "$UP_MARKER" && ! -f "$APPJSON" ]] \
  && grep -q 'not an exact commit object in this repository' "$WORK/out.log" \
  && ok "OLD runtime embedded commit that is not real repository history fails before receipt write" \
  || { bad "OLD non-ancestry case (rc=$RC up=$([[ -f "$UP_MARKER" ]] && echo yes || echo no) receipt=$([[ -f "$APPJSON" ]] && echo yes || echo no))"; cat "$WORK/out.log"; }

# Historical current runtime config_files (Finding 2): a container created by the OLD scheme labels
# its base as docker-compose.deploy.<shortsha>.yaml. That form is accepted ONLY when its bytes
# equal the trusted base blob at the running (OLD) commit.
HIST_BASE="$REPO_ROOT/docker-compose.deploy.$(printf '%s' "$OLD_GIT_SHA" | cut -c1-10).yaml"
git -C "$REPO_ROOT" show "$OLD_GIT_SHA:docker-compose.deploy.yaml" >"$HIST_BASE"
rm -rf "$REPO_ROOT/custom/wijaya/deploy/.receipts"
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" FAKE_CURRENT_BASE_LABEL="$HIST_BASE"
[[ "$RC" == 0 && -f "$APPJSON" && -f "$UP_MARKER" ]] \
  && grep -q 'current runtime config_files is an allowlisted base+catalog pair' "$WORK/out.log" \
  && ok "historical docker-compose.deploy.<shortsha>.yaml current label is accepted when its bytes equal the trusted runtime blob" \
  || { bad "historical label accept case (rc=$RC)"; cat "$WORK/out.log"; }

# A historical <shortsha> base whose bytes do NOT equal the trusted runtime blob is refused.
HIST_BAD="$REPO_ROOT/docker-compose.deploy.badc0ffee0.yaml"
printf 'version: "3"\nservices: {}\n# tampered historical base\n' >"$HIST_BAD"
rm -rf "$REPO_ROOT/custom/wijaya/deploy/.receipts"
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" FAKE_CURRENT_BASE_LABEL="$HIST_BAD"
[[ "$RC" != 0 && ! -f "$UP_MARKER" && ! -f "$APPJSON" ]] \
  && grep -q 'current runtime base compose bytes do not equal the trusted blob at the running commit' "$WORK/out.log" \
  && ok "tampered historical <shortsha> base label is refused before receipt write" \
  || { bad "historical label reject case (rc=$RC)"; cat "$WORK/out.log"; }
rm -f "$HIST_BAD"

# Both rails and sidekiq config_files labels must match each other (mixed app runtime refused).
rm -rf "$REPO_ROOT/custom/wijaya/deploy/.receipts"
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" FAKE_SIDEKIQ_CURRENT_BASE_LABEL="$HIST_BASE"
[[ "$RC" != 0 && ! -f "$UP_MARKER" && ! -f "$APPJSON" ]] \
  && grep -q 'rails and sidekiq config_files labels disagree' "$WORK/out.log" \
  && ok "divergent rails/sidekiq current config_files labels are refused before receipt write" \
  || { bad "mixed config_files label case (rc=$RC)"; cat "$WORK/out.log"; }
rm -f "$HIST_BASE"

# Service-scoped app deploys are REFUSED: rails and sidekiq always deploy together so a
# receipt (and its rollback) can never pin a half-updated app runtime. Only --service
# marine_sop_worker is permitted. Rejection happens at argument parsing, before any up.
run_deploy_app "$APP_FULL_SHA" rails "$CFG_OK"
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'service-scoped app deploy is not allowed' "$WORK/out.log" \
  && ok "--service rails is refused (rails+sidekiq deploy together), before any up" \
  || { bad "service-scoped rails deploy was not refused (rc=$RC)"; cat "$WORK/out.log"; }

run_deploy_app "$APP_FULL_SHA" sidekiq "$CFG_OK"
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'service-scoped app deploy is not allowed' "$WORK/out.log" \
  && ok "--service sidekiq is refused (rails+sidekiq deploy together), before any up" \
  || { bad "service-scoped sidekiq deploy was not refused (rc=$RC)"; cat "$WORK/out.log"; }

# Two selected services resolving to different immutable IDs must fail before up.
CFG_APP_SPLIT="$WORK/cfg_app_split.json"
jq '.services.rails.image = "rails:test" | .services.sidekiq.image = "sidekiq:test"' "$CFG_OK" >"$CFG_APP_SPLIT"
run_deploy_app "$APP_FULL_SHA" default "$CFG_APP_SPLIT" \
  FAKE_RAILS_REF='rails:test' FAKE_RAILS_ID="$APP_IMAGE_ID" \
  FAKE_SIDEKIQ_REF='sidekiq:test' FAKE_SIDEKIQ_ID="$APP_IMAGE_ID_B"
if [[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'resolve to different immutable image IDs' "$WORK/out.log"; then
  ok "different Rails/Sidekiq immutable IDs fail BEFORE compose up"
else
  bad "different app IDs were not blocked (rc=$RC)"; cat "$WORK/out.log"
fi

# Finding 2 (single-render TOCTOU closure): arm a tag retarget on a hypothetical SECOND render. The
# forward app lifecycle renders only ONCE (the single post-materialization render), so a trap armed
# beyond that single render must NEVER fire — the captured stdin bytes stay pinned to the verified
# immutable ID and no retargeted tag ever reaches the captured config or compose up. This replaces
# the former export+re-render pin tests: there is no post-verification re-render left to hijack.
rm -rf "$REPO_ROOT/custom/wijaya/deploy/.receipts"
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" FAKE_RETARGET_ON_RENDER=2
SR_CAPTURED="$WORK/captured.$CALLN"; SR_RENDERS="$(cat "$CONFIG_COUNT_FILE" 2>/dev/null || echo 0)"
if [[ "$RC" == 0 && "$SR_RENDERS" == 1 && -s "$SR_CAPTURED" ]] \
   && [[ "$(jq -r '.services.rails.image' "$SR_CAPTURED")" == "$APP_IMAGE_ID" ]] \
   && [[ "$(jq -r '.services.sidekiq.image' "$SR_CAPTURED")" == "$APP_IMAGE_ID" ]] \
   && ! grep -q 'retargeted-after-gate' "$SR_CAPTURED" \
   && ! grep -q 'retargeted-after-gate' "$UP_MARKER"; then
  ok "no post-verification Compose re-render exists: a retarget armed beyond the single render never reaches the captured bytes (renders=1, captured pinned to the verified immutable ID)"
else
  bad "single-render TOCTOU closure case (rc=$RC renders=$SR_RENDERS)"; cat "$WORK/out.log"
fi
rm -rf "$REPO_ROOT/custom/wijaya/deploy/.receipts"

# Existing fail-closed provenance outcomes remain covered.
run_deploy_app '0000000000000000000000000000000000000000' default "$CFG_OK"
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'does not match the expected target SHA' "$WORK/out.log" \
  && ok "mismatched app .git_sha blocks --deploy BEFORE compose up" \
  || { bad "app provenance mismatch case (rc=$RC)"; cat "$WORK/out.log"; }

run_deploy_app '' default "$CFG_OK"
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'embeds no readable /app/.git_sha' "$WORK/out.log" \
  && ok "empty/absent app .git_sha blocks --deploy BEFORE compose up" \
  || { bad "app provenance missing case (rc=$RC)"; cat "$WORK/out.log"; }

# Malformed embedded provenance must not be normalized by whitespace stripping.
run_deploy_app '3998c33fae bfb1ee5aca0a498deab738683f9ee7' default "$CFG_OK"
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'embeds a malformed /app/.git_sha' "$WORK/out.log" \
  && ok "whitespace-corrupted embedded app SHA fails closed BEFORE compose up" \
  || { bad "malformed embedded SHA case (rc=$RC)"; cat "$WORK/out.log"; }

# Bash command substitution must not normalize extra trailing newlines into a
# valid SHA. The fake prints its normal newline in addition to this injected one.
run_deploy_app "$APP_FULL_SHA"$'\n' default "$CFG_OK"
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'embeds a malformed /app/.git_sha' "$WORK/out.log" \
  && ok "extra trailing newline in embedded app SHA fails closed BEFORE compose up" \
  || { bad "extra trailing newline case (rc=$RC)"; cat "$WORK/out.log"; }

# The target is bound to repository HEAD and malformed/unavailable values still fail
# closed at the function boundary (source-only unit; no Docker call is reached).
rc=0
( export MARINE_DEPLOY_SOURCE_ONLY=1
  source "$DEPLOY_SH" --check >/dev/null 2>&1
  APP_EXPECTED_GIT_SHA='not-a-valid-sha'
  validate_app_image_provenance_before_recreate '{}' >"$WORK/invalid-target.log" 2>&1
) || rc=$?
[[ "$rc" != 0 ]] && grep -q 'requires a resolvable repository HEAD' "$WORK/invalid-target.log" \
  && ok "invalid repository target SHA fails closed before any image operation" \
  || { bad "invalid repository target SHA case (rc=$rc)"; cat "$WORK/invalid-target.log"; }

# Run the complete static contract, which enforces gate -> immutable pin ->
# re-render/assert -> recreate ordering and the single-entrypoint anti-bypass rule.
if bash "$CONTRACT_SH" >"$WORK/contract.log" 2>&1; then
  ok "static deploy contract enforces app pin ordering and anti-bypass rules"
else
  bad "static deploy contract failed"; cat "$WORK/contract.log"
fi

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

echo "== SOP sandbox gate (Blocker 2) =="

# 14) The pure SOP verdict parsers must extract the anchored sentinel lines while
#     ignoring boot noise, and treat FAIL tokens as failures.
( export MARINE_DEPLOY_SOURCE_ONLY=1
  source "$DEPLOY_SH" --check >/dev/null 2>&1
  [[ "$(parse_sop_selftest_verdict "$(printf 'boot noise\nWIJAYA_SOP_GATE:PASS\n')")" == PASS ]] || exit 61
  [[ "$(parse_sop_selftest_verdict "$(printf 'noise\nWIJAYA_SOP_GATE:FAIL:env-canary\nmore')")" == FAIL ]] || exit 62
  [[ -z "$(parse_sop_selftest_verdict 'only noise, no sentinel')" ]] || exit 63
  [[ "$(parse_sop_parent_verdict 'WIJAYA_SOP_PARENT:PASS')" == PASS ]] || exit 64
  [[ "$(parse_sop_parent_verdict "$(printf 'x\nWIJAYA_SOP_PARENT:FAIL\n')")" == FAIL ]] || exit 65
  [[ -z "$(parse_sop_parent_verdict 'nothing')" ]] || exit 66
  exit 0
) && ok "SOP sandbox/parent verdict parsers extract anchored sentinels and fail on FAIL tokens" \
  || bad "SOP sandbox verdict parsers (exit $?)"

# 15) The tracked in-container gate script must be syntactically valid POSIX sh and carry
#     the sentinel + cleanup contract (static checks only; the script itself runs only
#     inside the derivative container at deploy time).
if sh -n "$SOP_SANDBOX_GATE" 2>/dev/null; then
  ok "SOP sandbox gate script passes sh -n syntax check"
else
  bad "SOP sandbox gate script has shell syntax errors"
fi
grep -q 'WIJAYA_SOP_GATE:PASS' "$SOP_SANDBOX_GATE" \
  && ok "SOP sandbox gate script emits the tracked PASS sentinel" \
  || bad "SOP sandbox gate script missing the PASS sentinel"
grep -q 'SENTINEL:FAIL:$1' "$SOP_SANDBOX_GATE" \
  && grep -qE 'fail (launcher|su-exec|user|parser|selftest|env-canary|exec-target|kill-probe|pdfinfo|pdftotext|pdftoppm|tesseract)' "$SOP_SANDBOX_GATE" \
  && ok "SOP sandbox gate script has stable per-check failure tokens" \
  || bad "SOP sandbox gate script missing stable failure tokens"
grep -q 'trap cleanup EXIT' "$SOP_SANDBOX_GATE" \
  && ok "SOP sandbox gate script cleans up synthetic canaries on exit" \
  || bad "SOP sandbox gate script missing canary cleanup trap"
# Randomized exclusive mktemp canaries under storage/config/tmp (Blocker 2): no fixed
# predictable shared paths; cleanup removes exactly the created paths.
if grep -q 'mktemp /app/storage/.wijaya-sop-gate-canary' "$SOP_SANDBOX_GATE" \
   && grep -q 'mktemp /app/config/.wijaya-sop-gate-canary' "$SOP_SANDBOX_GATE" \
   && grep -q 'mktemp /tmp/.wijaya-sop-gate-canary' "$SOP_SANDBOX_GATE"; then
  ok "SOP sandbox gate uses randomized exclusive mktemp canaries under storage/config/tmp"
else
  bad "SOP sandbox gate canaries are not randomized/exclusive mktemp paths"
fi

# 16) The SOP overlay must blank integration secrets and never disable the sandbox
#     (static checks mirroring check_deploy_contract.sh, applied to the working tree).
if grep -q 'MARINE_SOP_SANDBOX_TEST_ONLY' "$SOP_OVERLAY"; then
  bad "SOP worker overlay sets the sandbox test-only opt-out"
else
  ok "SOP worker overlay never disables the child sandbox"
fi
blank_ok=1
for k in FB_APP_SECRET STRIPE_SECRET_KEY WHATSAPP_WEB_CONNECTOR_HMAC_SECRET WIJAYA_ERP_API_SECRET MARINE_CATALOG_PG_PASSWORD_FILE; do
  grep -qE "^[[:space:]]*- ${k}=[[:space:]]*$" "$SOP_OVERLAY" || blank_ok=0
done
[[ "$blank_ok" == 1 ]] \
  && ok "SOP worker overlay blanks integration secrets the OCR worker never uses" \
  || bad "SOP worker overlay is missing secret blankings"

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

echo "== minimal app-only receipt-backed rollback =="

RECEIPT_DIR="$REPO_ROOT/custom/wijaya/deploy/.receipts"
APPJSON="$RECEIPT_DIR/app.json"
LOCKFILE="$RECEIPT_DIR/.lock"

mk_app_receipt() {
  rm -rf "$RECEIPT_DIR"
  python3 "$RECEIPT_HELPER" ensure
  local base_fp catalog_fp
  base_fp="$(sha256sum "$BASE_COMPOSE" | cut -d' ' -f1)"
  catalog_fp="$(sha256sum "$CATALOG_OVERLAY" | cut -d' ' -f1)"
  jq -cn --argjson schema_version 1 --arg created_at '2026-10-26T00:00:00Z' \
    --arg target "$OLD_GIT_SHA" --arg image "$APP_IMAGE_ID_B" \
    --arg base "$base_fp" --arg catalog "$catalog_fp" \
    '{schema_version:$schema_version,created_at:$created_at,target_git_sha:$target,
      app_image_id:$image,services:["rails","sidekiq"],
      overlay_fingerprints:{base:$base,catalog:$catalog}}' \
    | python3 "$RECEIPT_HELPER" write
}

run_app_rollback() {
  CALLN=$((CALLN+1)); UP_MARKER="$WORK/up.rb.$CALLN"; IMAGE_MARKER="$WORK/img.rb.$CALLN"
  RUN_MARKER="$WORK/run.rb.$CALLN"; RB_STATE="$WORK/state.rb.$CALLN"; RB_CFGFILES="$WORK/cfg.rb.$CALLN"
  RB_CAPTURED="$WORK/captured.rb.$CALLN"; RB_COUNT="$WORK/config-count.rb.$CALLN"
  rm -f "$UP_MARKER" "$IMAGE_MARKER" "$RUN_MARKER" "$RB_STATE" "$RB_CFGFILES" "$RB_CAPTURED" "$RB_COUNT"; RC=0
  env DOCKER="$FAKE_DOCKER" \
    MARINE_DEPLOY_BASE_COMPOSE="$BASE_COMPOSE" MARINE_DEPLOY_CATALOG_OVERLAY="$CATALOG_OVERLAY" \
    MARINE_DEPLOY_SOP_OVERLAY="$SOP_OVERLAY" FAKE_CONFIG_JSON_FILE="$CFG_OK" \
    FAKE_CAPTURED_COMPOSE_FILE="$RB_CAPTURED" FAKE_CONFIG_COUNT_FILE="$RB_COUNT" \
    FAKE_UP_MARKER="$UP_MARKER" FAKE_IMAGE_MARKER="$IMAGE_MARKER" FAKE_RUN_MARKER="$RUN_MARKER" \
    FAKE_APP_REF='hokgt-chatwoot:test' FAKE_APP_ID="$APP_IMAGE_ID" FAKE_APP_GIT_SHA="$OLD_GIT_SHA" \
    FAKE_CONFIG_FILES_FILE="$RB_CFGFILES" FAKE_RUNTIME_STATE_FILE="$RB_STATE" FAKE_PS_IDS=1 \
    FAKE_RUNTIME_RAILS_IMAGE="$APP_IMAGE_ID" \
    FAKE_RUNTIME_SIDEKIQ_IMAGE='sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
    FAKE_MOUNT_RW=false MARINE_CURL="$WORK/curl_ok" "MARINE_MONITOR_LOG_CMD=printf ''" \
    "$@" bash "$DEPLOY_SH" --rollback >"$WORK/out.log" 2>&1 || RC=$?
}

# Recreation failure: receipt exists before first up, one rollback uses OLD, original RC survives.
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" \
  FAKE_UP_FAIL_FIRST=1 FAKE_UP_FAIL_STATUS=42 FAKE_REQUIRE_RECEIPT=1 FAKE_RECEIPT_FILE="$APPJSON"
lines="$(wc -l <"$UP_MARKER" 2>/dev/null || printf 0)"
if [[ "$RC" == 42 && "$lines" == 2 && -f "$APPJSON" ]] \
   && sed -n '1p' "$UP_MARKER" | grep -q "MARINE_DEPLOY_APP_IMAGE=$APP_IMAGE_ID" \
   && sed -n '2p' "$UP_MARKER" | grep -q "MARINE_DEPLOY_APP_IMAGE=$APP_IMAGE_ID_B" \
   && grep -q "^app=$APP_IMAGE_ID_B$" "$WORK/runstate.$CALLN"; then
  ok "failed NEW recreation writes receipt before up, rolls back exactly once to OLD, restores OLD, and preserves rc=42"
else bad "automatic rollback contract (rc=$RC lines=$lines)"; cat "$WORK/out.log"; fi

# Post-up HEALTH failure (NEW recreation succeeds, forward health gate fails): auto-roll-back once
# to OLD and exit with the original (health) failure status; the rollback itself is healthy.
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" \
  FAKE_REQUIRE_RECEIPT=1 FAKE_RECEIPT_FILE="$APPJSON" FAKE_PROBE_FAIL_ON_UPS=1
lines="$(wc -l <"$UP_MARKER" 2>/dev/null || printf 0)"
if [[ "$RC" == 1 && "$lines" == 2 && -f "$APPJSON" ]] \
   && sed -n '1p' "$UP_MARKER" | grep -q "MARINE_DEPLOY_APP_IMAGE=$APP_IMAGE_ID" \
   && sed -n '2p' "$UP_MARKER" | grep -q "MARINE_DEPLOY_APP_IMAGE=$APP_IMAGE_ID_B" \
   && grep -q "^app=$APP_IMAGE_ID_B$" "$WORK/runstate.$CALLN" \
   && grep -q 'automatic rollback to the app pre-deploy known-good completed' "$WORK/out.log"; then
  ok "post-up health failure auto-rolls-back to OLD (healthy) and preserves the original failure status"
else bad "post-up health failure rollback (rc=$RC lines=$lines)"; cat "$WORK/out.log"; fi

# Rollback COMPOSE failure: the forward up fails (42), the rollback up also fails; the original
# deploy status (42) must be preserved and the receipt retained for manual recovery.
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" \
  FAKE_UP_FAIL_FIRST=1 FAKE_UP_FAIL_STATUS=42 FAKE_ROLLBACK_UP_FAIL=1 FAKE_ROLLBACK_UP_FAIL_STATUS=55 \
  FAKE_REQUIRE_RECEIPT=1 FAKE_RECEIPT_FILE="$APPJSON"
if [[ "$RC" == 42 && -f "$APPJSON" ]] \
   && grep -q 'rollback compose up failed' "$WORK/out.log" \
   && grep -q 'automatic rollback failed; manual intervention required' "$WORK/out.log"; then
  ok "rollback compose failure preserves the ORIGINAL deploy status (42) and retains the receipt"
else bad "rollback compose failure (rc=$RC)"; cat "$WORK/out.log"; fi

# Rollback HEALTH failure: the forward up fails (42), the rollback up succeeds but its health gate
# fails; the original deploy status (42) must still be preserved.
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" \
  FAKE_UP_FAIL_FIRST=1 FAKE_UP_FAIL_STATUS=42 FAKE_PROBE_FAIL_ON_UPS=2 \
  FAKE_REQUIRE_RECEIPT=1 FAKE_RECEIPT_FILE="$APPJSON"
if [[ "$RC" == 42 && -f "$APPJSON" ]] \
   && grep -q 'automatic rollback failed; manual intervention required' "$WORK/out.log"; then
  ok "rollback health failure preserves the ORIGINAL deploy status (42) and retains the receipt"
else bad "rollback health failure (rc=$RC)"; cat "$WORK/out.log"; fi

# Explicit rollback does not inspect/capture the split/missing current app and keeps app.json
# stable. It recreates from the immutable per-commit assets it materializes for the receipt's
# target SHA (with --project-directory the repo), so the container config_files labels stay valid.
RB_ASSET_DIR="$REPO_ROOT/custom/wijaya/deploy/.receipts/assets/$OLD_GIT_SHA"
mk_app_receipt
receipt_before="$(sha256sum "$APPJSON" | cut -d' ' -f1)"
run_app_rollback FAKE_MISSING_BEFORE_UP=rails
receipt_after="$(sha256sum "$APPJSON" | cut -d' ' -f1)"
# Finding 2 — the rollback lifecycle renders Compose EXACTLY ONCE (after materialization): no
# preflight pre-render and no pin/capture re-render, so the total render count is 1.
rb_renders="$(cat "$RB_COUNT" 2>/dev/null || echo 0)"
if [[ "$RC" == 0 && "$receipt_before" == "$receipt_after" && "$rb_renders" == 1 ]] \
   && grep -q "MARINE_DEPLOY_APP_IMAGE=$APP_IMAGE_ID_B" "$UP_MARKER" \
   && grep -qF -- '--project-directory' "$UP_MARKER" \
   && grep -qF -- '-f - up' "$UP_MARKER" \
   && grep -q "^app=$APP_IMAGE_ID_B$" "$RB_STATE" \
   && [[ -f "$RB_ASSET_DIR/docker-compose.deploy.yaml" && -f "$RB_ASSET_DIR/docker-compose.marine-catalog.yml" ]] \
   && [[ -s "$RB_CAPTURED" ]] \
   && [[ "$(jq -r '.services.rails.image' "$RB_CAPTURED")" == "$APP_IMAGE_ID_B" ]] \
   && [[ "$(jq -r '.services.sidekiq.image' "$RB_CAPTURED")" == "$APP_IMAGE_ID_B" ]] \
   && [[ "$(jq -r '.services.rails.labels["com.wijaya.chatwoot.compose-source-revision"]' "$RB_CAPTURED")" == "$OLD_GIT_SHA" ]] \
   && [[ "$(jq -r '.services.rails.environment["MARINE_CATALOG_PG_PASSWORD_FILE"]' "$RB_CAPTURED")" == "/run/secrets/marine_catalog_pg_password" ]] \
   && [[ "$(jq -r '.services.rails.volumes[0].read_only' "$RB_CAPTURED")" == "true" ]] \
   && [[ "$(jq -r '.services.sidekiq.volumes[0].read_only' "$RB_CAPTURED")" == "true" ]]; then
  ok "explicit rollback renders Compose once after materialization, pins OLD in memory, leaves receipt unchanged, validates the captured catalog mount/service contract, and recreates from the captured target-commit config on stdin"
else bad "explicit app rollback (rc=$RC rb_renders=$rb_renders)"; cat "$WORK/out.log"; fi

# Repeated rollback is idempotent and still uses OLD.
run_app_rollback
[[ "$RC" == 0 && "$(sha256sum "$APPJSON" | cut -d' ' -f1)" == "$receipt_before" ]] \
  && grep -q "MARINE_DEPLOY_APP_IMAGE=$APP_IMAGE_ID_B" "$UP_MARKER" \
  && ok "repeated explicit rollback is idempotent (no reciprocal receipt)" \
  || { bad "repeated explicit rollback (rc=$RC)"; cat "$WORK/out.log"; }

# Receipt-fingerprint mismatch fails closed before mutation: rollback materializes the target
# commit's immutable asset and refuses when its bytes do not match the receipt fingerprint. (The
# working tree is irrelevant now — rollback uses the git blob, not the working-tree file.)
rm -rf "$RECEIPT_DIR"; python3 "$RECEIPT_HELPER" ensure
mismatch_base_fp="$(sha256sum "$BASE_COMPOSE" | cut -d' ' -f1)"
jq -cn --argjson schema_version 1 --arg created_at '2026-10-26T00:00:00Z' \
  --arg target "$OLD_GIT_SHA" --arg image "$APP_IMAGE_ID_B" --arg base "$mismatch_base_fp" \
  --arg catalog 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' \
  '{schema_version:$schema_version,created_at:$created_at,target_git_sha:$target,
    app_image_id:$image,services:["rails","sidekiq"],overlay_fingerprints:{base:$base,catalog:$catalog}}' \
  | python3 "$RECEIPT_HELPER" write
run_app_rollback
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] \
  && grep -q 'materialized catalog overlay bytes differ from the rollback receipt fingerprint' "$WORK/out.log" \
  && ok "rollback refuses when the materialized target-commit asset bytes differ from the receipt fingerprint, before compose up" \
  || { bad "receipt fingerprint mismatch refusal (rc=$RC)"; cat "$WORK/out.log"; }

# Receipt strictness: malformed JSON, symlink, loose mode, and non-integer schema_version.
receipt_rejected() {
  local label="$1" needle="$2"
  run_app_rollback
  [[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q "$needle" "$WORK/out.log" \
    && ok "$label receipt is rejected before compose up" \
    || { bad "$label receipt rejection (rc=$RC)"; cat "$WORK/out.log"; }
}
mk_app_receipt; printf 'not-json\n' >"$APPJSON"; chmod 600 "$APPJSON"
receipt_rejected malformed 'strict canonical validation'
mk_app_receipt; mv "$APPJSON" "$RECEIPT_DIR/real.json"; ln -s real.json "$APPJSON"
receipt_rejected symlink 'strict canonical validation'
mk_app_receipt; chmod 644 "$APPJSON"
receipt_rejected loose-mode 'strict canonical validation'
mk_app_receipt
python3 - "$APPJSON" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['schema_version']=True
open(p,'w').write(json.dumps(d,sort_keys=True,separators=(',',':'))+'\n')
PY
chmod 600 "$APPJSON"
receipt_rejected wrong-type 'strict canonical validation'

# The fixed lock gates app preflight/state reads.
mk_app_receipt
exec 9>"$LOCKFILE"; flock -n 9 || bad "could not hold fixture lifecycle lock"
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK"
if [[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'lifecycle lock held' "$WORK/out.log" \
   && ! grep -q 'required tools present' "$WORK/out.log" \
   && ! grep -q 'compose overlays resolved' "$WORK/out.log"; then
  ok "app lifecycle lock is acquired before tooling, preflight, and runtime reads"
else bad "lock ordering (rc=$RC)"; cat "$WORK/out.log"; fi
flock -u 9; exec 9>&-

# Retained-lock ordering (runtime discriminator): with the lifecycle lock HELD, an app --deploy
# must refuse AT THE LOCK before it validates ANY readiness tunable or performs any other
# top-level read. A poisoned readiness tunable would abort with its own distinctive message if
# validate_readiness_tunables (the FIRST top-level read) ran before the lock; a correct ordering
# never reaches it — the lock refusal wins. This fails if any top-level readiness/git/repo/
# project/tool/state read precedes the lock re-exec.
mk_app_receipt
exec 9>"$LOCKFILE"; flock -n 9 || bad "could not hold fixture lifecycle lock (readiness-ordering)"
run_deploy_app "$APP_FULL_SHA" default "$CFG_OK" MARINE_PUBLIC_HTTP_MAX_ATTEMPTS=not-a-number
if [[ "$RC" != 0 && ! -f "$UP_MARKER" ]] \
   && grep -q 'lifecycle lock held' "$WORK/out.log" \
   && ! grep -q 'MARINE_PUBLIC_HTTP_MAX_ATTEMPTS must be a positive integer' "$WORK/out.log" \
   && ! grep -q 'required tools present' "$WORK/out.log" \
   && ! grep -q 'compose overlays resolved' "$WORK/out.log"; then
  ok "lifecycle lock is taken BEFORE readiness-tunable validation and every other top-level read (held lock beats a poisoned tunable)"
else bad "readiness-before-lock ordering (rc=$RC)"; cat "$WORK/out.log"; fi
flock -u 9; exec 9>&-

# Retained-lock ordering (static): the lifecycle-lock gate must be invoked at the very TOP of the
# entrypoint — before readiness-tunable validation, the git repo-root resolution, the working-dir
# change, and argument parsing. A read that precedes the gate reintroduces the ordering violation.
gate_line="$(grep -nF 'enter_lifecycle_lock_before_any_read "$@"' "$DEPLOY_SH" | tail -1 | cut -d: -f1 || true)"
readiness_call_line="$(grep -nxF 'validate_readiness_tunables' "$DEPLOY_SH" | head -1 | cut -d: -f1 || true)"
repo_resolve_line="$(grep -nF 'REPO_ROOT="$(resolve_repo_root)"' "$DEPLOY_SH" | head -1 | cut -d: -f1 || true)"
cd_line="$(grep -nF 'cd "$REPO_ROOT"' "$DEPLOY_SH" | head -1 | cut -d: -f1 || true)"
parse_line="$(grep -nxF 'parse_args "$@"' "$DEPLOY_SH" | head -1 | cut -d: -f1 || true)"
if [[ -n "$gate_line" && -n "$readiness_call_line" && -n "$repo_resolve_line" && -n "$cd_line" && -n "$parse_line" \
   && "$gate_line" -lt "$readiness_call_line" && "$gate_line" -lt "$repo_resolve_line" \
   && "$gate_line" -lt "$cd_line" && "$gate_line" -lt "$parse_line" ]]; then
  ok "lock gate precedes readiness validation, git repo resolution, cd, and argument parsing (no pre-lock state read)"
else
  bad "lock-gate static ordering (gate=$gate_line readiness=$readiness_call_line repo=$repo_resolve_line cd=$cd_line parse=$parse_line)"
fi

# Finding 1 — the inherited lock fd is bound to the ORIGINAL canonical lock identity (dev+ino)
# exported by lock-exec, validated BEFORE owner/type/mode/flock and NEVER re-derived from the
# pathname at verify time. The helper refuses anything whose dev/ino differs from that exported
# original, and a replaced/hard-linked .lock pathname can never redefine the expected identity.
mk_app_receipt
read LOCK_DEV LOCK_INO < <(python3 -c 'import os,sys;st=os.stat(sys.argv[1]);print(st.st_dev,st.st_ino)' "$LOCKFILE")
vfd() { MARINE_LIFECYCLE_LOCK_DEV="$LOCK_DEV" MARINE_LIFECYCLE_LOCK_INO="$LOCK_INO" python3 "$RECEIPT_HELPER" verify-inherited-fd "$@"; }
# (c0) a missing exported original identity is refused outright (there is no identity to bind to).
rc=0; MARINE_LIFECYCLE_LOCK_DEV= MARINE_LIFECYCLE_LOCK_INO= python3 "$RECEIPT_HELPER" verify-inherited-fd 8 8<"$LOCKFILE" >"$WORK/vfd0.log" 2>&1 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'missing-original-lock-identity' "$WORK/vfd0.log" \
  && ok "verify-inherited-fd refuses when the exported original lock identity is absent" \
  || { bad "missing original identity not refused (rc=$rc)"; cat "$WORK/vfd0.log"; }
# (c1) a closed fd is rejected via fstat EBADF (never reopening the lock pathname).
rc=0; vfd 7 7>&- >"$WORK/vfd1.log" 2>&1 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'closed-or-invalid-lock-fd' "$WORK/vfd1.log" \
  && ok "verify-inherited-fd rejects a closed/invalid fd without reopening the lock pathname" \
  || { bad "closed inherited fd not rejected (rc=$rc)"; cat "$WORK/vfd1.log"; }
# (c2) a live, owned, regular 0644 fd is NOT the original lock inode — rejected on the dev+ino
# binding (before the mode check), proving a forged marker cannot point at a non-lock file.
FORGED="$WORK/forged_lock"; : >"$FORGED"; chmod 644 "$FORGED"
rc=0; vfd 7 7<"$FORGED" >"$WORK/vfd2.log" 2>&1 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'inherited-fd-not-original-lock' "$WORK/vfd2.log" \
  && ok "verify-inherited-fd rejects a forged non-lock inherited fd on the original dev+ino binding" \
  || { bad "forged non-lock inherited fd not rejected (rc=$rc)"; cat "$WORK/vfd2.log"; }
# (c3) the genuine held 0600 lock fd is ACCEPTED (proves the check is not a blanket deny).
rc=0
exec 8<>"$LOCKFILE"; flock -n 8 || bad "could not hold lock for verify-inherited-fd accept case"
vfd 8 >"$WORK/vfd3.log" 2>&1 || rc=$?
[[ "$rc" == 0 ]] && grep -q 'inherited-lock-fd=8' "$WORK/vfd3.log" \
  && ok "verify-inherited-fd accepts the genuine held 0600 lock fd (original dev+ino match + flock, no pathname redefine)" \
  || { bad "genuine held lock fd rejected (rc=$rc)"; cat "$WORK/vfd3.log"; }
flock -u 8; exec 8>&-
# (c4) an UNRELATED owner-only 0600 regular file passes owner/type/mode but is NOT the original lock
# inode — rejected on the dev+ino binding.
UNREL_LOCK="$WORK/unrelated_0600_regular"; : >"$UNREL_LOCK"; chmod 600 "$UNREL_LOCK"
rc=0; vfd 7 7<"$UNREL_LOCK" >"$WORK/vfd4.log" 2>&1 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'inherited-fd-not-original-lock' "$WORK/vfd4.log" \
  && ok "verify-inherited-fd rejects an unrelated 0600 regular file (dev+ino != original lock)" \
  || { bad "unrelated 0600 regular fd not bound to the original lock (rc=$rc)"; cat "$WORK/vfd4.log"; }
# (c5) a 0600 memfd (anonymous, owner-only, regular) is likewise rejected: its device+inode can
# never equal the original lock. The forged fd is created then exec's the real helper so the genuine
# verify-inherited-fd command receives it as an inherited fd (exported original passed via env).
rc=0; MARINE_LIFECYCLE_LOCK_DEV="$LOCK_DEV" MARINE_LIFECYCLE_LOCK_INO="$LOCK_INO" python3 - "$RECEIPT_HELPER" >"$WORK/vfd5.log" 2>&1 <<'PY' || rc=$?
import os, sys
fd = os.memfd_create("marine-forged-lock", 0)
os.fchmod(fd, 0o600)
os.set_inheritable(fd, True)
os.execv(sys.executable, [sys.executable, sys.argv[1], "verify-inherited-fd", str(fd)])
PY
[[ "$rc" != 0 ]] && grep -q 'inherited-fd-not-original-lock' "$WORK/vfd5.log" \
  && ok "verify-inherited-fd rejects a 0600 memfd (dev+ino != original lock)" \
  || { bad "0600 memfd not bound to the original lock (rc=$rc)"; cat "$WORK/vfd5.log"; }
# (c6) Adversarial replacement race (Finding 1): AFTER lock-exec captured the ORIGINAL dev+ino, an
# attacker replaces/hard-links the canonical .lock pathname to an unrelated 0600 file AND points the
# forged inherited fd at that same file. Re-deriving identity from the pathname would ACCEPT (fd ==
# re-opened path); binding to the exported original REJECTS, because the forged file's dev+ino differ
# from the original.
UNREL_ATTACK="$WORK/attacker_0600"; : >"$UNREL_ATTACK"; chmod 600 "$UNREL_ATTACK"
rm -f "$LOCKFILE"; ln "$UNREL_ATTACK" "$LOCKFILE"
rc=0; vfd 7 7<"$UNREL_ATTACK" >"$WORK/vfd6.log" 2>&1 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'inherited-fd-not-original-lock' "$WORK/vfd6.log" \
  && ok "verify-inherited-fd binds to the ORIGINAL exported dev+ino: a .lock swapped/hard-linked to a forged 0600 file (matching the forged fd) is still rejected" \
  || { bad "original-identity binding against pathname replacement (rc=$rc)"; cat "$WORK/vfd6.log"; }
mk_app_receipt
read LOCK_DEV LOCK_INO < <(python3 -c 'import os,sys;st=os.stat(sys.argv[1]);print(st.st_dev,st.st_ino)' "$LOCKFILE")
# (c7) Canonical-path corroboration: even with a GENUINE inherited lock fd, if the canonical .lock
# pathname has been swapped to a different inode, verify fails closed — the pathname can never
# redefine the expected (original) identity.
exec 8<>"$LOCKFILE"; flock -n 8 || bad "could not hold lock for canonical-swap case"
SWAP="$WORK/swapped_canonical_0600"; : >"$SWAP"; chmod 600 "$SWAP"
rm -f "$LOCKFILE"; ln "$SWAP" "$LOCKFILE"
rc=0; vfd 8 >"$WORK/vfd7.log" 2>&1 || rc=$?
flock -u 8; exec 8>&-
[[ "$rc" != 0 ]] && grep -q 'canonical-lock-path-replaced' "$WORK/vfd7.log" \
  && ok "verify-inherited-fd fails closed when the canonical .lock pathname is swapped from the original inode even with a genuine fd (pathname never redefines expected identity)" \
  || { bad "canonical path replacement not detected (rc=$rc)"; cat "$WORK/vfd7.log"; }
mk_app_receipt

# deploy.sh must VALIDATE the inherited fd, not trust the numeric marker: a forged
# MARINE_LIFECYCLE_LOCK_FD pointing at a non-lock (0644) fd is refused before any read/up.
FORGED2="$WORK/forged_marker_fd"; : >"$FORGED2"; chmod 644 "$FORGED2"
CALLN=$((CALLN+1)); UP_MARKER="$WORK/up.forged.$CALLN"; rm -f "$UP_MARKER"; RC=0
env DOCKER="$FAKE_DOCKER" MARINE_DEPLOY_BASE_COMPOSE="$BASE_COMPOSE" \
    MARINE_DEPLOY_CATALOG_OVERLAY="$CATALOG_OVERLAY" MARINE_DEPLOY_SOP_OVERLAY="$SOP_OVERLAY" \
    FAKE_CONFIG_JSON_FILE="$CFG_OK" FAKE_UP_MARKER="$UP_MARKER" \
    MARINE_LIFECYCLE_LOCK_FD=6 \
    bash "$DEPLOY_SH" --deploy 6<"$FORGED2" >"$WORK/out.log" 2>&1 || RC=$?
if [[ "$RC" != 0 && ! -f "$UP_MARKER" ]] \
   && grep -q 'inherited lifecycle lock fd failed validation' "$WORK/out.log" \
   && ! grep -q 'required tools present' "$WORK/out.log"; then
  ok "deploy.sh refuses a forged inherited lock-fd marker (validates the fd, never trusts the number) before any read/up"
else bad "forged inherited marker not refused (rc=$RC)"; cat "$WORK/out.log"; fi

# SOP-only remains receipt-less; combined and rollback+SOP requests fail closed.
mk_app_receipt
receipt_before="$(sha256sum "$APPJSON" | cut -d' ' -f1)"
run_deploy_sop_deploy 'WIJAYA_SOP_GATE:PASS' "$CFG_SOP_OK"
[[ "$RC" == 0 && "$(sha256sum "$APPJSON" | cut -d' ' -f1)" == "$receipt_before" ]] \
  && ok "SOP-only deploy behavior remains receipt-less and does not alter app.json" \
  || { bad "SOP-only receipt isolation (rc=$RC)"; cat "$WORK/out.log"; }
CALLN=$((CALLN+1)); UP_MARKER="$WORK/up.combined.$CALLN"; rm -f "$UP_MARKER"; RC=0
env DOCKER="$FAKE_DOCKER" FAKE_UP_MARKER="$UP_MARKER" bash "$DEPLOY_SH" --deploy --with-sop-worker >"$WORK/out.log" 2>&1 || RC=$?
[[ "$RC" != 0 && ! -f "$UP_MARKER" ]] && grep -q 'atomic cross-scope rollback is unavailable' "$WORK/out.log" \
  && ok "combined app+SOP deploy is rejected because atomic cross-scope rollback is unsupported" \
  || { bad "combined deploy rejection (rc=$RC)"; cat "$WORK/out.log"; }
RC=0
env DOCKER="$FAKE_DOCKER" FAKE_UP_MARKER="$UP_MARKER" bash "$DEPLOY_SH" --rollback --with-sop-worker >"$WORK/out.log" 2>&1 || RC=$?
[[ "$RC" != 0 ]] && grep -q -- '--rollback is app-only' "$WORK/out.log" \
  && ok "--rollback rejects SOP flags/service selection" \
  || { bad "rollback SOP rejection (rc=$RC)"; cat "$WORK/out.log"; }

# Production source has no receipt/test-mode path override and no multi-scope receipt machinery.
if ! grep -qE 'MARINE_DEPLOY_(RECEIPT_DIR|TEST_MODE)|combined\.json|sop\.json|materialize_overlay|roll-forward' "$DEPLOY_SH"; then
  ok "production deploy source exposes only fixed app.json/lock and no multi-scope state machine"
else bad "obsolete/path-overridable receipt machinery remains"; fi

echo "-------------------------------------------"
echo "PASS=$pass FAIL=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "Deployment-contract tests OK"
