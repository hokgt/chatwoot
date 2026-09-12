# WIJAYA_CUSTOM_START deferred_auto_assignment
# One-time automatic historical reconciliation trigger — ordered AFTER all schema prerequisites.
#
# This replaces the original enqueue in 20260912000001 (now a no-op). It runs only once every
# schema dependency the corrected ReconciliationJob/Reconciler needs is in place:
#   - 20260912000000 created the provenance + run-ledger tables;
#   - 20260912000002 added the marker correlation columns (reconciliation_generation /
#     reconciliation_outcome) and the full run counter set (identified / assigned /
#     no_eligible_agent / dropped / failed / retries).
# Migrations run in filename (version) order, so by the time this executes those columns exist and
# no worker can consume the job against an incomplete schema.
#
# It mirrors the established Chatwoot convention of a migration enqueuing a background job (see
# EnqueueValidateOpenaiHooksJob): recorded once in schema_migrations, giving a durable,
# non-recurring completion boundary — no recurring blanket scan on every boot.
#
# The enqueued ReconciliationJob scans ONLY the durable provenance rows (never all unassigned
# conversations), in bounded batches, idempotently, guarded by the
# wijaya_deferred_reconciliation_runs ledger keyed on this migration's version as the generation.
# Fail-open: if the optional battery is absent the constant will not resolve, so the enqueue is
# guarded and the migration still completes.
class EnqueueDeferredAssignmentReconciliationAfterSchema < ActiveRecord::Migration[7.1]
  GENERATION = '20260912000003'.freeze

  def up
    return unless defined?(Wijaya::Batteries::DeferredAutoAssignment::ReconciliationJob)

    Wijaya::Batteries::DeferredAutoAssignment::ReconciliationJob.perform_later(generation: GENERATION)
  end

  def down; end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
