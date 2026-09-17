# WIJAYA_CUSTOM_START deferred_auto_assignment
# One-time automatic historical reconciliation — persisted as DURABLE run intent, not a Redis job.
#
# This runs once every schema prerequisite the corrected ReconciliationJob/Reconciler needs is in
# place (20260912000000 created the tables; 20260912000002 added the correlation columns + full
# counter set). It replaces the original in 20260912000001 (now a no-op).
#
# It does NOT enqueue a Redis ActiveJob (perform_later). Relying on a one-shot enqueue inside a
# migration is fragile: a Redis outage, or an OLD Sidekiq worker consuming the job in the deploy
# window before new code/schema is fully in place, would silently drop the only trigger and the
# one-time reconciliation would never run. Instead the migration INSERTs a durable, persisted run
# intent — a wijaya_deferred_reconciliation_runs row in status 'running' with started_at NULL (never
# executed yet) and cutoff_at = the deploy instant (full history up to deploy). The recurring
# RecoveryDrainerJob is the coordinator: on each tick it adopts the oldest incomplete run and runs the
# Reconciler INLINE (under its global advisory lock — it never enqueues ReconciliationJob), so this
# intent is resumed until it truthfully completes — surviving Redis downtime and old-worker timing
# entirely, because the run executes later under new code with the full schema.
#
# Idempotent (INSERT ... WHERE NOT EXISTS on the unique generation), so a re-run of the migration
# never creates a second intent, and the ledger's unique generation keeps the run one-time. On this
# install the run scans ZERO rows (the provenance table is new); its ledger still completes truthfully.
class EnqueueDeferredAssignmentReconciliationAfterSchema < ActiveRecord::Migration[7.1]
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
