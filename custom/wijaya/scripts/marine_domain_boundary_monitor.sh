#!/usr/bin/env bash
# =============================================================================
# Marine domain-boundary dependency monitor (secret-safe).
#
# Scans a BOUNDED window of rails+sidekiq logs and distinguishes:
#
#   * INTERNAL DEPENDENCY ALERTS (exit nonzero) — an internal domain-boundary
#     dependency (catalog, LLM provider/config, or malformed output) failed and
#     Marine is degrading to the fail-closed safe fallback:
#       - "domain_boundary.fallback category=error"
#       - "Marine::Catalog::Errors::CatalogUnavailableError"
#
#   * LEGITIMATE SEMANTIC DENIALS (never alert) — the guard correctly refused an
#     out-of-scope / adversarial turn:
#       - category=unrelated
#       - category=extraction
#       - category=override
#
# It NEVER prints customer messages, model outputs, credentials, or raw log lines
# — only structured counts and the window bound. Exit code is nonzero on an
# internal dependency alert OR on a log-collection failure, so a healthy stream
# (including legitimate denials) passes.
#
# Usage:
#   custom/wijaya/scripts/marine_domain_boundary_monitor.sh [--since <epoch|duration>]
#
# --since accepts a unix epoch (as emitted by the deploy health gate) or a Go
# duration such as 10m / 1h. Defaults to 10m so historical errors outside the
# window never cause a permanent false failure.
#
# Log collection is fail-closed: if the log source cannot be read (docker/compose
# failure, or the test seam command exiting nonzero), the monitor emits a secret-safe
# collection-error status and exits nonzero WITHOUT evaluating or printing any captured
# output. It never falls back to "assume healthy".
#
# Test seam: MARINE_MONITOR_LOG_CMD may override the log source with a command
# that prints candidate log lines to stdout (used by the unit tests instead of a
# live docker daemon). Its exit status is honoured — a nonzero seam command triggers
# the same fail-closed collection-error path as a live-log fetch failure.
# =============================================================================
set -euo pipefail

DOCKER="${DOCKER:-docker}"
SINCE='10m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) shift || { echo "--since requires a value" >&2; exit 2; }
             [[ $# -gt 0 ]] || { echo "--since requires a value" >&2; exit 2; }
             SINCE="$1" ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    *) echo "unsupported argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# Resolve repo root + compose files (only used for the default log source).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || ( cd "$script_dir/../../.." && pwd ))"
base_compose="${MARINE_DEPLOY_BASE_COMPOSE:-$repo_root/docker-compose.deploy.yaml}"
catalog_overlay="${MARINE_DEPLOY_CATALOG_OVERLAY:-$repo_root/custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-catalog.yml}"

# Internal-dependency alert patterns (fail-closed catalog degradation). Note the
# leading-anchored "category=error" so a category=unrelated/extraction/override
# semantic denial is NEVER matched.
INTERNAL_ALERT_RE='domain_boundary\.fallback category=error|Marine::Catalog::Errors::CatalogUnavailableError'
# Legitimate semantic-denial categories (counted for visibility, never alerting).
SEMANTIC_RE='domain_boundary\.(deny|fallback) category=(unrelated|extraction|override)'

# Fetch candidate log lines to stdout. Returns the source's exit status; stderr is
# suppressed so no raw error/log content can leak. Callers MUST honour the status and
# fail closed — never treat an unreadable source as an empty (healthy) stream.
fetch_logs() {
  if [[ -n "${MARINE_MONITOR_LOG_CMD:-}" ]]; then
    bash -c "$MARINE_MONITOR_LOG_CMD" 2>/dev/null
    return $?
  fi
  "$DOCKER" compose -f "$base_compose" -f "$catalog_overlay" \
    logs --no-color --since "$SINCE" rails sidekiq 2>/dev/null
  return $?
}

# Fail closed if log collection fails: emit a secret-safe collection-error status and exit
# nonzero WITHOUT printing the captured output (which may hold raw log/error content).
if ! logs="$(fetch_logs)"; then
  printf '{"window_since":"%s","status":"log_collection_error","internal_dependency_alerts":null,"semantic_denials":null}\n' \
    "$SINCE"
  echo "ALERT: Marine domain-boundary log collection failed; no logs evaluated (fail-closed)" >&2
  exit 3
fi

internal_count="$(grep -cE "$INTERNAL_ALERT_RE" <<<"$logs" || true)"
semantic_count="$(grep -cE "$SEMANTIC_RE" <<<"$logs" || true)"
internal_count="${internal_count:-0}"
semantic_count="${semantic_count:-0}"

# Structured, secret-safe summary (counts only — never the log lines themselves).
printf '{"window_since":"%s","internal_dependency_alerts":%d,"semantic_denials":%d}\n' \
  "$SINCE" "$internal_count" "$semantic_count"

if [[ "$internal_count" -gt 0 ]]; then
  echo "ALERT: internal Marine domain-boundary dependency error(s) detected in window (catalog, LLM provider/config, or malformed output)" >&2
  exit 1
fi
exit 0
