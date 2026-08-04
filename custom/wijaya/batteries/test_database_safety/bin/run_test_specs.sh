#!/usr/bin/env bash
#
# Wijaya containerized test runner -- fail-safe test-database isolation.
# =====================================================================
#
# WHY THIS EXISTS
# ---------------
# The incident: `docker compose run ... -e RAILS_ENV=test base ...` inherited
# POSTGRES_DATABASE=chatwoot_production from the Compose env_file, so RAILS_ENV=test
# tasks migrated production and attempted db:test:purge there.
#
# The fix is NOT to hide the env_file (the app legitimately needs its connection
# host/user/password). The fix is to make the generic POSTGRES_DATABASE irrelevant
# to test-database selection: the pure-Ruby guard in this battery ignores it, uses
# POSTGRES_TEST_DATABASE (default chatwoot_test), validates any DATABASE_URL, and
# fails closed. This wrapper drives that guard from the SAME one-off container that
# then runs the real command, so nothing touches a database until the effective
# test database has been proven test-only.
#
# WHY `docker compose run --rm -T base`
# -------------------------------------
# The compose `base` service image (chatwoot:development) is built with the test and
# development gem groups (BUNDLE_WITHOUT=''), unlike the slim production deploy image.
# It is referenced by SERVICE NAME, never a commit-pinned image tag, so this wrapper
# does not go stale. The live working tree is bind-mounted at /app so uncommitted
# code (this guard, new specs) runs as-is. Connection host/user/password come from
# the compose env_file; the guard renders the leaked POSTGRES_DATABASE harmless.
#
# USAGE
# -----
#   custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh [command...]
#
# Default command is `bundle exec rspec`. Any extra args are passed through, e.g.:
#   .../run_test_specs.sh bundle exec rspec spec/custom/wijaya/test_database_safety
#   .../run_test_specs.sh bundle exec rails db:migrate
#
# CONFIGURATION (env overrides; safe defaults)
# --------------------------------------------
#   WIJAYA_TEST_SERVICE    Compose service to run  (default: base)
#   POSTGRES_TEST_DATABASE Test database name      (default: chatwoot_test)
#
# This wrapper forces RAILS_ENV=test / NODE_ENV=test, sets BUNDLE_WITHOUT='' so test
# gems load, sets an explicit test-only POSTGRES_TEST_DATABASE, and clears (unsets)
# the generic DATABASE_URL. It never sets POSTGRES_DATABASE; the guard ignores whatever
# the env_file provides. Suitable for subsequent Marine Commit 1B verification.
#
set -euo pipefail

# Derive the repository root from this script's location (never hardcoded). The
# script lives at custom/wijaya/batteries/test_database_safety/bin/, five levels
# below the repo root.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"

SERVICE="${WIJAYA_TEST_SERVICE:-base}"
PG_TEST_DB="${POSTGRES_TEST_DATABASE:-chatwoot_test}"

# Command to run inside the container (default: full rspec suite).
if [[ "$#" -gt 0 ]]; then
  RUN_CMD=("$@")
else
  RUN_CMD=(bundle exec rspec)
fi

echo "[wijaya:test_database_safety] service=${SERVICE} root=${ROOT} test_db=${PG_TEST_DB}"

# DATABASE_URL and FRONTEND_URL are cleared with `unset` (NOT set to ""). Rails
# 7.1 treats an empty DATABASE_URL as present and refuses to boot, so it must be
# truly unset. FRONTEND_URL is also unset so test behavior matches CI defaults
# instead of inheriting a dev/production host from the Compose env_file. The
# repository `.env` is masked below, preventing dotenv-rails from restoring either
# value after this preflight. This also prevents test redirects and generated URLs
# from targeting the live dev host. The pure guard then prints/validates the effective
# database name via resolve!; on any unsafe value the guard prints a sanitized refusal
# and exits nonzero, so `set -e` aborts here BEFORE the real command (and thus before
# ActiveRecord connects). POSTGRES_DATABASE is intentionally NOT set; the guard ignores
# whatever the env_file provides.
CONTAINER_SCRIPT='
set -eu
git config --global --add safe.directory /app
unset DATABASE_URL FRONTEND_URL
echo "[wijaya:test_database_safety] effective RAILS_ENV=${RAILS_ENV}"
EFFECTIVE_DB="$(ruby -r./custom/wijaya/batteries/test_database_safety/guard \
  -e "print Wijaya::Batteries::TestDatabaseSafety::Guard.resolve!")"
echo "[wijaya:test_database_safety] effective test database = ${EFFECTIVE_DB}"
exec "$@"
'

exec docker compose run --rm -T --no-deps \
  -v "${ROOT}:/app" \
  -v /dev/null:/app/.env:ro \
  -w /app \
  -e RAILS_ENV=test \
  -e NODE_ENV=test \
  -e BUNDLE_WITHOUT= \
  -e POSTGRES_TEST_DATABASE="${PG_TEST_DB}" \
  "${SERVICE}" \
  sh -c "${CONTAINER_SCRIPT}" wijaya-test-runner "${RUN_CMD[@]}"
