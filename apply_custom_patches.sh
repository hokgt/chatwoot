#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Current Wijaya customizations are stored in-tree as batteries plus minimal
# WIJAYA_CUSTOM hook calls. Reapplying after an upstream pull must be idempotent AND
# able to REATTACH any hook blocks an upstream merge dropped — verifying alone is not
# enough to satisfy that rule.
#
# The custom_roles battery owns the applicator for the native Captain
# tasks_controller hook blocks added by the composer-task security fix
# (custom_roles_rbac): run it first so those blocks are reattached before
# anything else, then the other batteries' applicators, then the global checker.
#
# whatsapp_web_inbox owns a deterministic, idempotent, context-safe applicator that
# reinserts only its missing marker blocks (exact anchors, atomic writes, fails loudly on
# an absent/ambiguous anchor without partial writes). Run it first, then verify every
# battery's files/markers via the global checker. If all blocks are already present the
# applicator is a no-op and leaves no diff.
#
# The deferred_auto_assignment and marine_ai batteries own deterministic applicators for their
# marker-wrapped Sidekiq schedule entries. Deferred must run first because Marine inserts after its
# end marker. All applicators are no-ops when their exact blocks exist.
if command -v python3 >/dev/null 2>&1; then
  python3 "$ROOT/custom/wijaya/batteries/proxy_https/patch/apply_patches.py"
  python3 "$ROOT/custom/wijaya/batteries/custom_roles/patch/apply_patches.py"
  python3 "$ROOT/custom/wijaya/batteries/whatsapp_web_inbox/patch/apply_patches.py"
  python3 "$ROOT/custom/wijaya/batteries/deferred_auto_assignment/patch/apply_patches.py"
  python3 "$ROOT/custom/wijaya/batteries/marine_ai/patch/apply_patches.py"
else
  echo "WARN: python3 not found — skipping custom hook applicators; verifying only." >&2
fi

exec "$ROOT/check_custom_patches.sh"
