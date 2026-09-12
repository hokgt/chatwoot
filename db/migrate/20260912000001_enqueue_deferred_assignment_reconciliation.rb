# WIJAYA_CUSTOM_START deferred_auto_assignment
# One-time automatic historical reconciliation trigger. Mirrors the established Chatwoot
# convention of a migration enqueuing a background job (see EnqueueValidateOpenaiHooksJob):
# migrations run exactly once at deploy (release phase) and are recorded in schema_migrations,
# giving a durable, non-recurring completion boundary — no recurring blanket scan on every boot.
#
# The enqueued ReconciliationJob scans ONLY the durable provenance rows (never all unassigned
# conversations), in bounded batches, idempotently, guarded by the wijaya_deferred_reconciliation_runs
# ledger keyed on this migration's version as the generation. Fail-open: if the optional battery
# is absent the constant will not resolve, so the enqueue is guarded and the migration still
# completes.
class EnqueueDeferredAssignmentReconciliation < ActiveRecord::Migration[7.1]
  GENERATION = '20260912000001'.freeze

  def up
    return unless defined?(Wijaya::Batteries::DeferredAutoAssignment::ReconciliationJob)

    Wijaya::Batteries::DeferredAutoAssignment::ReconciliationJob.perform_later(generation: GENERATION)
  end

  def down; end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
