# WIJAYA_CUSTOM_START deferred_auto_assignment
# Durable structured provenance for the deferred auto-assignment battery.
#
# wijaya_deferred_assignment_provenance is a tombstone/event log: exactly one row per
# conversation captured when an agent deletion cleared that conversation's assignee. It is
# written ATOMICALLY inside Agents::DestroyJob's unassignment transaction (savepoint-wrapped,
# fail-open), so a crash between that commit and the existing post-commit dispatch can be
# reconciled later from a structured, authoritative source instead of guessed from free-text
# activity. It records account, conversation, inbox, the PRIOR human agent id, the removal
# event + time, and a reconciled_at cursor for idempotent one-time reconciliation.
#
# prior_assignee_id carries NO foreign key on purpose: the whole scenario is that the agent
# (User) is subsequently deleted, and a cascading FK would erase the very provenance we need.
# account/conversation/inbox keep on_delete: cascade — if the account or conversation itself is
# gone there is nothing left to reassign, so cascading there preserves integrity without losing
# anything actionable. No message content and no credentials are ever stored.
#
# wijaya_deferred_reconciliation_runs is the persisted run/cutoff/completion ledger for the
# one-time historical reconciliation (see ReconciliationJob). A unique generation makes the
# reconciliation idempotent and non-recurring: a completed generation is never re-scanned.
#
# The table name is long, so every index gets an explicit short name to stay under Postgres's
# 63-character identifier limit.
class CreateWijayaDeferredAssignmentProvenance < ActiveRecord::Migration[7.1]
  def change
    create_provenance_table
    create_reconciliation_runs_table
  end

  def create_provenance_table
    create_table :wijaya_deferred_assignment_provenance do |t|
      cascade = { on_delete: :cascade }
      t.references :account, null: false, foreign_key: cascade, index: { name: 'idx_wijaya_deferred_prov_on_account' }
      t.references :conversation, null: false, foreign_key: cascade, index: { name: 'idx_wijaya_deferred_prov_on_conversation' }
      t.references :inbox, null: false, foreign_key: cascade, index: { name: 'idx_wijaya_deferred_prov_on_inbox' }
      # The prior human agent's id. Deliberately NOT a foreign key: the agent is deleted, and a
      # cascading FK would destroy the provenance. Indexed for reconciliation lookups.
      t.bigint :prior_assignee_id, null: false, index: { name: 'idx_wijaya_deferred_prov_on_prior_assignee' }
      # Structured removal event + time (never parsed from free text). Currently only the
      # agent-deletion path writes here; the column keeps the design open to future events.
      t.string :event, null: false, default: 'agent_deletion'
      t.datetime :event_at, null: false
      # Reconciliation cursor: NULL until the one-time reconciliation has processed this row.
      t.datetime :reconciled_at, index: { name: 'idx_wijaya_deferred_prov_on_reconciled_at' }
      t.timestamps
    end

    # One provenance row per (conversation, prior agent, event): a retried DestroyJob re-dispatch
    # of the same ids can never create a duplicate tombstone.
    add_index :wijaya_deferred_assignment_provenance,
              %i[conversation_id prior_assignee_id event],
              unique: true,
              name: 'idx_wijaya_deferred_prov_unique_event'
  end

  def create_reconciliation_runs_table
    create_table :wijaya_deferred_reconciliation_runs do |t|
      # Identifies a single one-time reconciliation trigger (the enqueue migration's version).
      # Unique so re-enqueuing/retrying never starts a second run for the same generation.
      t.string :generation, null: false
      t.datetime :cutoff_at
      t.string :status, null: false, default: 'running'
      t.integer :scanned, null: false, default: 0
      t.integer :registered, null: false, default: 0
      t.integer :skipped, null: false, default: 0
      t.integer :ambiguous, null: false, default: 0
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end
    add_index :wijaya_deferred_reconciliation_runs, :generation,
              unique: true, name: 'idx_wijaya_deferred_recon_runs_on_generation'
  end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
