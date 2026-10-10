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
  if grep -q "$CATALOG_ENV" "$SOP"; then
    err "SOP worker overlay must NOT carry the catalog secret ($CATALOG_ENV)"
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
