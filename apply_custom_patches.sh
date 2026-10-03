#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Current Wijaya customizations are stored in-tree as batteries plus minimal
# WIJAYA_CUSTOM hook calls. Reapplying after an upstream pull must be idempotent AND
# able to REATTACH any hook blocks an upstream merge dropped — verifying alone is not
# enough to satisfy that rule.
#
# whatsapp_web_inbox owns a deterministic, idempotent, context-safe applicator that
# reinserts only its missing marker blocks (exact anchors, atomic writes, fails loudly on
# an absent/ambiguous anchor without partial writes). Run it first, then verify every
# battery's files/markers via the global checker. If all blocks are already present the
# applicator is a no-op and leaves no diff.
#
# The registered marine_ai price-display-v1 battery artifacts carry no upstream marker
# hooks — they are verified through the checker's file/marker assertions below.
if command -v python3 >/dev/null 2>&1; then
  python3 "$ROOT/custom/wijaya/batteries/whatsapp_web_inbox/patch/apply_patches.py"
else
  echo "WARN: python3 not found — skipping whatsapp_web_inbox hook applicator; verifying only." >&2
fi

exec "$ROOT/check_custom_patches.sh"
