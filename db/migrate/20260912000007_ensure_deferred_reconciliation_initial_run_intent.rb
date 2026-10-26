# WIJAYA_CUSTOM_START deferred_auto_assignment
# Forward repair for the DURABLE one-time reconciliation run intent.
#
# 20260912000003 was later rewritten (in place) from a fragile Redis perform_later into an INSERT of
# a persisted 'running' run intent. Editing an already-applied migration does NOT re-run it: any
# environment that recorded the OLD 20260912000003 in schema_migrations before the rewrite executed
# its original body (the enqueue, or nothing if Redis was down) and will NEVER execute the rewritten
# up — so the durable run intent the RecoveryDrainerJob coordinator resumes would simply never exist,
# and the one-time historical reconciliation would silently never run there.
#
# This NEW forward migration reconciles that drift the correct way (never a history rewrite): it
# idempotently ensures the exact one-time initial ReconciliationRun intent exists — generation
# '20260912000003', status 'running', started_at NULL (never executed yet), cutoff_at = the deploy
# instant (full history up to this upgrade). It does NOT enqueue Redis; the recurring
# RecoveryDrainerJob coordinator (re-)runs every incomplete intent until it truthfully completes.
#
# Idempotent by the run's unique generation (INSERT ... WHERE NOT EXISTS): it NO-OPS when the intent
# already exists in ANY state — a fresh install where 20260912000003 already inserted it (status
# 'running'), or an old-000003 install where the original Redis job already ran to completion (status
# 'completed'). A re-run of this migration therefore never creates a second intent. On a fresh
# install this is pure belt-and-suspenders; on a drifted old-000003 install it is the repair.
class EnsureDeferredReconciliationInitialRunIntent < ActiveRecord::Migration[7.1]
  GENERATION = '20260912000003'.freeze
  RUNS_TABLE = 'wijaya_deferred_reconciliation_runs'.freeze

  def up
    return unless table_exists?(RUNS_TABLE)

    execute(<<~SQL.squish)
      INSERT INTO #{RUNS_TABLE} (generation, status, cutoff_at, started_at, created_at, updated_at)
      SELECT #{quote(GENERATION)}, 'running', NOW(), NULL, NOW(), NOW()
      WHERE NOT EXISTS (SELECT 1 FROM #{RUNS_TABLE} WHERE generation = #{quote(GENERATION)})
    SQL
  end

  def down; end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
