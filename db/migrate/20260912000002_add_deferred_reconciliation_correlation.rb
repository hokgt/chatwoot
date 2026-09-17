# WIJAYA_CUSTOM_START deferred_auto_assignment
# Corrective schema for the provenance-backed automatic reconciliation (follows, never edits,
# the already-committed 20260912000000/20260912000001 migrations — those may already be recorded
# in schema_migrations, so the new correlation/counters land in a separate additive migration
# per Rails convention).
#
# wijaya_deferred_assignments gains two NULLABLE reconciliation-correlation columns. They are NULL
# for every existing (creation / agent-deletion-bridge / historical) marker, so those markers are
# completely unchanged; only a marker adopted by the reconciliation carries a generation, letting
# the shared InboxProcessor attribute its actual assignment outcome back to the run that created
# it. reconciliation_outcome records that marker's latest recorded async disposition so a repeated
# "no eligible agent" pass is never double-counted and a later assignment/drop transitions cleanly.
#
# wijaya_deferred_reconciliation_runs gains the remaining REQUIRED observability counters
# (identified / assigned / no_eligible_agent / dropped / failed / retries) alongside the existing
# scanned / registered / skipped / ambiguous, so a run's ledger truthfully reports every disposition
# from provenance scan through the existing Marker -> ProcessInboxJob -> InboxProcessor path.
class AddDeferredReconciliationCorrelation < ActiveRecord::Migration[7.1]
  def change
    add_column :wijaya_deferred_assignments, :reconciliation_generation, :string
    add_column :wijaya_deferred_assignments, :reconciliation_outcome, :string
    add_index :wijaya_deferred_assignments, :reconciliation_generation,
              name: 'idx_wijaya_deferred_asg_on_recon_generation'

    add_column :wijaya_deferred_reconciliation_runs, :identified, :integer, null: false, default: 0
    add_column :wijaya_deferred_reconciliation_runs, :assigned, :integer, null: false, default: 0
    add_column :wijaya_deferred_reconciliation_runs, :no_eligible_agent, :integer, null: false, default: 0
    add_column :wijaya_deferred_reconciliation_runs, :dropped, :integer, null: false, default: 0
    add_column :wijaya_deferred_reconciliation_runs, :failed, :integer, null: false, default: 0
    add_column :wijaya_deferred_reconciliation_runs, :retries, :integer, null: false, default: 0
  end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
