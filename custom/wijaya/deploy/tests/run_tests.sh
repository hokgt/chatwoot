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
SOP_SANDBOX_GATE="$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/sop_sandbox_gate.sh"
SOP_SANDBOX_C="$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/wijaya_sop_sandbox.c"
SOP_DOCKERFILE="$REPO_ROOT/custom/wijaya/batteries/marine_ai/deploy/Dockerfile.sop-processing"

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
      # Mirror real compose env substitution: once deploy.sh pins
      # MARINE_SOP_IMAGE to the verified immutable image ID, the resolved
      # config must show that ID for the SOP worker.
      if [[ -n "${MARINE_SOP_IMAGE:-}" ]]; then
        jq --arg img "$MARINE_SOP_IMAGE" '.services["marine_sop_worker"].image = $img' "${FAKE_CONFIG_JSON_FILE:?}"
      else
        cat "${FAKE_CONFIG_JSON_FILE:?}"
      fi
      exit 0 ;;
    up)      : "${FAKE_UP_MARKER:?}"
              printf 'up MARINE_SOP_IMAGE=%s\n' "${MARINE_SOP_IMAGE:-}" >>"$FAKE_UP_MARKER"
              exit 0 ;;
    *) exit 0 ;;
  esac
elif [[ "${1:-}" == "run" ]]; then
  # docker run invocations from deploy.sh: the embedded /app/.git_sha provenance
  # read (from the exact image ID) and the pre-image SOP sandbox gate. Both are
  # recorded (exact argv) so tests can prove which image ref was used; only the
  # configured embedded sha / gate verdict is ever emitted.
  : "${FAKE_RUN_MARKER:?}"
  printf '%s\n' "$*" >>"${FAKE_RUN_MARKER}"
  case "$*" in
    *'/app/.git_sha'*) printf '%s\n' "${FAKE_SOP_GIT_SHA:-}"; exit 0 ;;
    *) printf '%s\n' "${FAKE_PRE_IMAGE_GATE_OUT:-WIJAYA_SOP_GATE:PASS}"; exit 0 ;;
  esac
elif [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  : "${FAKE_IMAGE_MARKER:?}"
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
  elif [[ "$ref" == "${FAKE_APP_REF:-}" ]]; then
    case "$fmt" in *'.Id'*) echo "${FAKE_APP_ID:-}" ;; esac
  fi
  exit 0
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

FULL_SHA='0123456789abcdef0123456789abcdef01234567'
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
      FAKE_SOP_ID='sha256:sop' FAKE_APP_ID='sha256:app' \
      FAKE_SOP_SOURCE="$FULL_SHA" FAKE_SOP_BASE='hokgt-chatwoot:test' \
      FAKE_SOP_ROLE='marine_sop_worker' \
      FAKE_SOP_GIT_SHA="$git_sha" \
      bash "$DEPLOY_SH" --deploy --with-sop-worker >"$WORK/out.log" 2>&1 || RC=$?
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
if grep -q '^up MARINE_SOP_IMAGE=sha256:sop$' "$UP_MARKER"; then
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
recreate_line="$(grep -n '^  recreate_services$' "$DEPLOY_SH" | head -1 | cut -d: -f1 || true)"
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

echo "-------------------------------------------"
echo "PASS=$pass FAIL=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "Deployment-contract tests OK"
