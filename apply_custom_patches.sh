#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Current Wijaya customizations are stored in-tree as batteries plus minimal
# WIJAYA_CUSTOM hook calls. Reapplying after an upstream pull is idempotent: this
# script verifies the expected battery files and hook markers are present.
#
# The registered marine_ai price-display-v1 battery artifacts (PriceDisplayFormatter,
# PriceReplyComposer, en/id price_available locales, and their specs) carry no upstream
# marker hooks — they are verified through the checker's file/marker assertions below.
exec "$ROOT/check_custom_patches.sh"
