#!/usr/bin/env bash
# =============================================================================
# Static deployment-contract checker (no Docker, no mutation).
#
# Verifies the Development deployment contract holds in the tree:
#   1. The canonical entrypoint uses the base compose + MANDATORY catalog overlay.
#   2. The retired overlay filename has ZERO references in tracked files.
#   3. The catalog overlay declares a read-only catalog mount for BOTH rails and
#      sidekiq (and the container-path env contract).
#   4. The optional SOP worker overlay stays optional and carries NO catalog mount.
#   5. No competing tracked deployment/recreation entrypoint under custom/wijaya
#      bypasses the canonical entrypoint.
#
# Exit nonzero on any violation. Safe to run in CI; invoked by check_custom_patches.sh.
# =============================================================================
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null \
        || ( cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd ))"
cd "$ROOT"

fail=0
err() { echo "DEPLOY-CONTRACT: $*" >&2; fail=1; }

# Does this shell file contain an EXECUTABLE (non-comment) deployment/recreation bypass —
# a `--force-recreate`, or a `docker compose ... up` / `docker-compose ... up` invocation?
# Comment lines and trailing inline comments are stripped first so docs never false-match.
# Pure (reads a file, no side effects) so the regression suite can exercise it directly.
file_has_recreation_bypass() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -vE '^[[:space:]]*#' "$f" 2>/dev/null \
    | sed 's/[[:space:]]#.*$//' \
    | grep -qE '(--force-recreate|docker[ -]compose.*[[:space:]]up([[:space:]]|$))'
}

# Does ANY file in the supplied list reference the retired overlay needle? Skips .hermes
# build snapshots and uses `grep -I` so binary/secret content is never read or emitted —
# we return only a boolean, never the matching line. Pure (reads files, no side effects) so
# the regression suite can exercise it directly.
retired_reference_in_list() {
  local needle="$1"; shift
  local f
  for f in "$@"; do
    [[ -z "$f" ]] && continue
    case "$f" in .hermes|.hermes/*) continue ;; esac
    [[ -f "$f" ]] || continue
    grep -qI -- "$needle" "$f" 2>/dev/null && return 0
  done
  return 1
}

CANONICAL='custom/wijaya/deploy/deploy.sh'
CATALOG='custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-catalog.yml'
SOP='custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-sop-worker.yml'
SOP_DOCKERFILE='custom/wijaya/batteries/marine_ai/deploy/Dockerfile.sop-processing'
SOP_SANDBOX_C='custom/wijaya/batteries/marine_ai/deploy/wijaya_sop_sandbox.c'
SOP_SANDBOX_GATE='custom/wijaya/batteries/marine_ai/deploy/sop_sandbox_gate.sh'
BASE_NEEDLE='docker-compose.deploy.yaml'
CATALOG_NEEDLE='docker-compose.marine-catalog.yml'
CATALOG_ENV='MARINE_CATALOG_PG_PASSWORD_FILE'
# Assemble the retired filename at runtime so this checker never literally embeds
# it (prevents a false self-match in the tracked-reference scan below).
OLD_OVERLAY="docker-compose.marine-""sop.yml"

# When sourced by the regression suite (DEPLOY_CONTRACT_SOURCE_ONLY=1) stop here so the
# pure matcher above can be unit-tested without running the tree-wide checks below.
if [[ "${DEPLOY_CONTRACT_SOURCE_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

# 1) Canonical entrypoint references base + mandatory catalog overlay.
if [[ ! -f "$CANONICAL" ]]; then
  err "canonical entrypoint missing: $CANONICAL"
else
  grep -q "$BASE_NEEDLE" "$CANONICAL"    || err "canonical entrypoint does not use base compose ($BASE_NEEDLE)"
  grep -q "$CATALOG_NEEDLE" "$CANONICAL" || err "canonical entrypoint does not use the mandatory catalog overlay"
  grep -q -- '--force-recreate' "$CANONICAL" || err "canonical entrypoint does not force-recreate"
  grep -q -- '--no-build' "$CANONICAL"       || err "canonical entrypoint does not pin --no-build"
fi

# 2) Retired overlay filename has no references in tracked OR untracked-not-ignored files
#    under the repository. A committed reference AND a working-tree reference that has not
#    been committed yet are both caught. .hermes build snapshots are excluded, and `grep -I`
#    skips binary files so no secret/binary content is ever read or emitted.
scan_files=()
while IFS= read -r f; do
  [[ -n "$f" ]] && scan_files+=("$f")
done < <( { git ls-files; git ls-files --others --exclude-standard; } | sort -u )
if retired_reference_in_list "$OLD_OVERLAY" "${scan_files[@]}"; then
  err "retired overlay filename '$OLD_OVERLAY' is still referenced (tracked or untracked-not-ignored file)"
fi
if [[ -f "custom/wijaya/batteries/marine_ai/deploy/$OLD_OVERLAY" ]]; then
  err "retired overlay file still exists on disk"
fi

# 3) Catalog overlay: read-only mount + env contract for rails AND sidekiq.
if [[ ! -f "$CATALOG" ]]; then
  err "mandatory catalog overlay missing: $CATALOG"
else
  grep -qE '^[[:space:]]*rails:'   "$CATALOG" || err "catalog overlay missing rails service"
  grep -qE '^[[:space:]]*sidekiq:' "$CATALOG" || err "catalog overlay missing sidekiq service"
  grep -q "$CATALOG_ENV" "$CATALOG"           || err "catalog overlay missing $CATALOG_ENV contract"
  ro_count="$(grep -cE ':ro([[:space:]]|$)' "$CATALOG" || true)"
  [[ "${ro_count:-0}" -ge 2 ]] || err "catalog overlay must declare a read-only (:ro) mount for both rails and sidekiq"
fi

# 4) SOP worker overlay stays optional and carries NO catalog mount.
if [[ ! -f "$SOP" ]]; then
  err "SOP worker overlay missing: $SOP"
else
  grep -q 'marine_sop_worker' "$SOP" || err "SOP overlay does not define marine_sop_worker"
  grep -q 'MARINE_SOP_IMAGE' "$SOP" || err "SOP overlay must use a dedicated MARINE_SOP_IMAGE"
  grep -q 'MARINE_SOP_SOURCE_REVISION' "$SOP" || err "SOP overlay must declare the exact source revision"
  grep -q 'com.wijaya.chatwoot.base-image' "$SOP" || err "SOP overlay must declare the base image provenance"
  grep -q 'com.wijaya.chatwoot.overlay' "$SOP" || err "SOP overlay must declare its tracked overlay identity"
  if grep -qE '^[[:space:]]*image:[[:space:]]*\$\{CHATWOOT_IMAGE' "$SOP"; then
    err "SOP worker must not reuse CHATWOOT_IMAGE; use a dedicated derivative image"
  fi
  grep -qE "^[[:space:]]*-[[:space:]]*${CATALOG_ENV}=[[:space:]]*$" "$SOP" \
    || err "SOP worker overlay must explicitly blank $CATALOG_ENV inherited from .env"
  if grep -q 'marine_catalog_ro_password' "$SOP"; then
    err "SOP worker overlay must NOT mount the catalog secret"
  fi
  # Blocker 2: the overlay must never disable the child sandbox or isolate the parent
  # network (the worker legitimately needs DB/Redis/ActiveStorage connectivity).
  if grep -q 'MARINE_SOP_SANDBOX_TEST_ONLY' "$SOP"; then
    err "SOP worker overlay must NOT set the sandbox test-only opt-out"
  fi
  if grep -qE '^[[:space:]]*network_mode:' "$SOP"; then
    err "SOP worker overlay must NOT change container networking"
  fi
  # Final review round: the parent keeps ONLY the capabilities it needs — KILL
  # must be among them so CommandRunner can SIGKILL its su-exec-dropped child
  # process group (hard deadline enforcement) — while the CHILD gets zero
  # capabilities (su-exec clears them; the launcher verifies via capget).
  grep -q -- '- KILL' "$SOP" \
    || err "SOP worker overlay must retain KILL in cap_add (parent must SIGKILL its privilege-dropped child process group)"
  grep -qE '^[[:space:]]*- ALL$' "$SOP" || err "SOP worker overlay must keep cap_drop ALL"
  grep -q 'no-new-privileges:true' "$SOP" || err "SOP worker overlay must keep security_opt no-new-privileges:true"
fi

# 4b) Blocker 2 — SOP sandbox launcher contract (static, no Docker).
# The derivative Dockerfile must compile the tracked Landlock+seccomp launcher at the
# fixed path CommandRunner expects, and the tracked in-container runtime gate must
# exist and emit the anchored verdict sentinel.
if [[ ! -s "$SOP_SANDBOX_C" ]]; then
  err "SOP sandbox launcher source missing: $SOP_SANDBOX_C"
else
  grep -q '__NR_socket' "$SOP_SANDBOX_C" || err "SOP sandbox launcher must deny socket syscalls"
  grep -q '__NR_io_uring_setup' "$SOP_SANDBOX_C" || err "SOP sandbox launcher must deny io_uring syscalls (side-channel)"
  grep -q '__NR_setsid' "$SOP_SANDBOX_C" || err "SOP sandbox launcher must deny session escape (setsid)"
  grep -q '__NR_setpgid' "$SOP_SANDBOX_C" || err "SOP sandbox launcher must deny process-group escape (setpgid)"
  grep -q 'landlock' "$SOP_SANDBOX_C" || err "SOP sandbox launcher must apply a Landlock policy"
  grep -q 'EXEC_MODE_ALLOWLIST' "$SOP_SANDBOX_C" || err "SOP sandbox launcher must enforce the exact exec-mode argv target allowlist"
  grep -q '__NR_capget' "$SOP_SANDBOX_C" \
    || err "SOP sandbox launcher must fail closed on nonzero effective/permitted capabilities (direct capget before any policy/exec)"
fi
if [[ ! -s "$SOP_DOCKERFILE" ]]; then
  err "SOP derivative Dockerfile missing: $SOP_DOCKERFILE"
else
  grep -q 'wijaya_sop_sandbox.c' "$SOP_DOCKERFILE" || err "SOP Dockerfile must compile the tracked sandbox launcher source"
  grep -q '/usr/local/bin/wijaya-sop-sandbox' "$SOP_DOCKERFILE" || err "SOP Dockerfile must install the launcher at the fixed allowlisted path"
  grep -q '/app/.git_sha' "$SOP_DOCKERFILE" \
    || err "SOP Dockerfile must fail the build unless the embedded /app/.git_sha equals the full SOURCE_REVISION (before labels)"
fi
if [[ ! -s "$SOP_SANDBOX_GATE" ]]; then
  err "SOP sandbox runtime gate script missing: $SOP_SANDBOX_GATE"
else
  grep -q 'WIJAYA_SOP_GATE' "$SOP_SANDBOX_GATE" || err "SOP sandbox gate must emit the tracked verdict sentinel"
  grep -q 'WIJAYA_SOP_SELFTEST:PASS' "$SOP_SANDBOX_GATE" || err "SOP sandbox gate must require the launcher self-test verdict"
  grep -q 'cleanup()' "$SOP_SANDBOX_GATE" || err "SOP sandbox gate must clean up its synthetic canaries"
  grep -q 'mktemp /app/storage/.wijaya-sop-gate-canary' "$SOP_SANDBOX_GATE" \
    || err "SOP sandbox gate canaries must be randomized exclusive mktemp paths"
  grep -q 'kill-probe' "$SOP_SANDBOX_GATE" \
    || err "SOP sandbox gate must prove parent CAP_KILL over a real su-exec-dropped marine_sop process group"
  grep -q 'IO.pipe' "$SOP_SANDBOX_GATE" \
    || err "SOP sandbox gate kill probe must wait on a private IO.pipe readiness handshake"
  grep -q '>&3' "$SOP_SANDBOX_GATE" \
    || err "SOP sandbox gate kill probe must prove the su-exec uid/gid drop (fixed byte on inherited fd 3) before killing"
fi

# 4c) Blocker 2 — pre-image SOP sandbox gate (predeploy): deploy.sh must run the SAME
# tracked in-container gate inside an ephemeral --network none container of the EXACT
# target SOP derivative image BEFORE any compose up (recreate_services).
if [[ -f "$CANONICAL" ]]; then
  grep -q 'run --rm --network none' "$CANONICAL" \
    || err "canonical entrypoint must run the pre-image SOP sandbox gate in an ephemeral --network none container"
  # Blocker 2 fix contract: the pre-image gate must be SELF-CONTAINED — an
  # isolated EMPTY tmpfs at /app/storage (the derivative image has no /app/storage;
  # never the runtime storage_data volume or host/customer data), isolated tmpfs
  # /tmp, the worker's capability set (cap_drop ALL + CHOWN/SETUID/SETGID/KILL),
  # no-new-privileges, and pids/memory bounds. It must never volume-mount
  # /app/storage into the ephemeral gate container.
  grep -qF -- '--tmpfs /app/storage:rw,nosuid,nodev' "$CANONICAL" \
    || err "pre-image gate must mount an isolated empty tmpfs at /app/storage (never the runtime storage volume)"
  grep -qF -- '--tmpfs /tmp:rw,nosuid,nodev,size=256m,mode=1777' "$CANONICAL" \
    || err "pre-image gate must use an isolated tmpfs /tmp"
  grep -qF -- '--cap-drop ALL' "$CANONICAL" \
    || err "pre-image gate must drop all capabilities"
  for c in CHOWN SETUID SETGID KILL; do
    grep -qF -- "--cap-add $c" "$CANONICAL" \
      || err "pre-image gate must mirror the worker capability set (--cap-add $c missing)"
  done
  grep -qF -- '--security-opt no-new-privileges' "$CANONICAL" \
    || err "pre-image gate must set no-new-privileges"
  grep -qF -- '--pids-limit 256' "$CANONICAL" \
    || err "pre-image gate must set a pids bound"
  grep -qF -- '--memory 2g' "$CANONICAL" \
    || err "pre-image gate must set a memory bound"
  if grep -nE -- 'run .*(-v |--volume )' "$CANONICAL" | grep -v -- '-v /dev/null'; then
    err "pre-image gate must not volume-mount host/runtime storage (no -v/--volume in docker run)"
  fi
  grep -q 'gate_sop_sandbox_pre_image' "$CANONICAL" \
    || err "canonical entrypoint missing the pre-image SOP sandbox gate"
  gate_line="$(grep -n 'gate_sop_sandbox_pre_image' "$CANONICAL" | head -1 | cut -d: -f1 || true)"
  recreate_line="$(grep -n 'recreate_services' "$CANONICAL" | head -1 | cut -d: -f1 || true)"
  if [[ -z "${gate_line:-}" || -z "${recreate_line:-}" || "$gate_line" -ge "$recreate_line" ]]; then
    err "pre-image SOP sandbox gate must be invoked before recreate_services in the canonical entrypoint"
  fi
  # Final review round (Blocker 3): recreation must be pinned to the EXACT
  # verified immutable image ID, before the gate and compose up — the mutable
  # tag is never dereferenced again after verification (no TOCTOU).
  grep -q 'SOP_VERIFIED_IMAGE_ID' "$CANONICAL" \
    || err "canonical entrypoint must bind the verified immutable SOP image ID before recreation"
  pin_line="$(grep -n 'export MARINE_SOP_IMAGE=' "$CANONICAL" | head -1 | cut -d: -f1 || true)"
  gate_call_line="$(grep -n 'gate_sop_sandbox_pre_image "\$json"' "$CANONICAL" | head -1 | cut -d: -f1 || true)"
  if [[ -z "${pin_line:-}" || -z "${gate_call_line:-}" || "$pin_line" -ge "$gate_call_line" ]]; then
    err "canonical entrypoint must pin MARINE_SOP_IMAGE to the verified image ID BEFORE the pre-image SOP sandbox gate"
  fi
fi

# 5) No competing recreation/`up` entrypoint under custom/wijaya. Only the canonical
#    entrypoint may force-recreate or run `docker compose up`. A checker that scanned only
#    `--force-recreate` would miss a competing script doing a plain `docker compose ... up`
#    (which silently omits the mandatory catalog overlay). The scan covers shell scripts
#    both tracked and untracked-not-ignored (so a working-tree bypass is caught before it
#    is ever committed); the canonical entrypoint, this checker, and tests (under */tests/)
#    legitimately carry the pattern and are excluded.
SELF="custom/wijaya/scripts/check_deploy_contract.sh"
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ "$f" == *.sh ]] || continue
  [[ "$f" == "$CANONICAL" ]] && continue
  [[ "$f" == "$SELF" ]] && continue
  case "$f" in
    */tests/*) continue ;;
  esac
  if file_has_recreation_bypass "$f"; then
    err "competing deployment/recreation entrypoint bypasses the canonical script: $f"
  fi
done < <( { git ls-files -- 'custom/wijaya'; git ls-files --others --exclude-standard -- 'custom/wijaya'; } | sort -u )

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "Deploy contract OK"
