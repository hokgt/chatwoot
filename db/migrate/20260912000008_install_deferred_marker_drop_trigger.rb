# WIJAYA_CUSTOM_START deferred_auto_assignment
# Installs the PostgreSQL BEFORE DELETE trigger that keeps the reconciliation run ledger's
# terminal-disposition counters truthful when a reconciliation-owned marker is removed by a DB-level
# DELETE that fires no Rails callback — the on_delete: :cascade paths established by
# 20260912000005 (conversation.delete_all / destroy_async / any parent FK cascade).
#
# Without it, a cascade deletes a still-waiting marker without transitioning its run counter, so the
# ledger keeps a stale no_eligible_agent and misses the dropped it should record. The trigger fires
# inside the same transaction as the DELETE, so its ledger UPDATE is atomic with the marker removal
# and rolls back with it. Marker.resolve_and_record suppresses the trigger for its own delete (via
# the SET LOCAL wijaya.deferred_skip_marker_drop GUC) because it records the precise ASSIGNED/DROPPED
# outcome in Ruby, so the two sources never double-count.
#
# The trigger is declared with the repository's HairTrigger create_trigger DSL (the same DSL the
# upstream conversations/campaigns display-id triggers use). HairTrigger emits the trigger FUNCTION
# before the CREATE TRIGGER — and schema.rb dumps it as a matching create_trigger block, so a fresh
# db:schema:load reconstructs it in the correct order. This migration therefore covers BOTH
# migrate-forward installs and (via the schema dump it produces) fresh-schema installs; there is no
# boot-time DDL. The SQL body is inlined as a literal (no application-model dependency) so
# HairTrigger's migration reader can reconstruct it when regenerating schema.rb.
#
# Reversible: down drops the trigger and its generated function.
class InstallDeferredMarkerDropTrigger < ActiveRecord::Migration[7.1]
  # rubocop:disable Metrics/MethodLength
  def up
    # Rails/SquishedSQLHeredocs disabled: the multi-line body is kept verbatim so the migration source
    # and the create_trigger block dumped into db/schema.rb stay identical and human-readable.
    create_trigger('wijaya_deferred_marker_drop_trg', generated: true, compatibility: 1)
      .on('wijaya_deferred_assignments')
      .before(:delete)
      .for_each(:row) do
        <<~SQL # rubocop:disable Rails/SquishedSQLHeredocs
          IF OLD.reconciliation_generation IS NULL OR OLD.reconciliation_generation = '' THEN
            RETURN OLD;
          END IF;
          IF current_setting('wijaya.deferred_skip_marker_drop', true) = 'on' THEN
            RETURN OLD;
          END IF;
          IF OLD.reconciliation_outcome = 'dropped' THEN
            RETURN OLD;
          END IF;
          UPDATE wijaya_deferred_reconciliation_runs
             SET dropped = dropped + 1,
                 no_eligible_agent = CASE WHEN OLD.reconciliation_outcome = 'no_eligible_agent'
                   THEN GREATEST(no_eligible_agent - 1, 0) ELSE no_eligible_agent END,
                 assigned = CASE WHEN OLD.reconciliation_outcome = 'assigned'
                   THEN GREATEST(assigned - 1, 0) ELSE assigned END,
                 updated_at = NOW()
           WHERE generation = OLD.reconciliation_generation;
          RETURN OLD;
        SQL
      end
  end
  # rubocop:enable Metrics/MethodLength

  def down
    drop_trigger('wijaya_deferred_marker_drop_trg', 'wijaya_deferred_assignments')
  end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
