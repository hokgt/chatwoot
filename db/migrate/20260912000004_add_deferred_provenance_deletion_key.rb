# WIJAYA_CUSTOM_START deferred_auto_assignment
# Durable per-deletion-occurrence idempotency key for the provenance tombstone.
#
# The original unique index (conversation_id, prior_assignee_id, event) collapsed DISTINCT
# deletion occurrences of the same conversation+agent into one row: once agent A had been removed
# from an account (tombstone recorded + reconciled), a later re-add of A and a SECOND removal of the
# same conversation could not record its own tombstone (find_or_create_by! matched the old, already
# reconciled row), so the second occurrence was silently lost and its conversation stranded.
#
# deletion_key carries a value STABLE across retries of the SAME deletion (the Agents::DestroyJob
# ActiveJob job_id, preserved across ActiveJob/Sidekiq retries) but DISTINCT for a genuinely new
# deletion occurrence. Uniqueness therefore moves to (conversation_id, prior_assignee_id, event,
# deletion_key): a retry of one deletion still dedupes, while removing the same conversation+agent
# again later records a new, independently reconcilable tombstone.
#
# Pre-key rows are backfilled to a constant sentinel ('legacy'). Each already existed under the old
# 3-column unique index, so they remain mutually unique under the 4-column index; a real deletion's
# UUID job_id can never collide with the sentinel.
#
# Forward-only (never edits the already-applied 20260912000000 that created the old index).
#
# IRREVERSIBLE by design. The whole point of the 4-column index is to let DISTINCT deletion
# occurrences of the same conversation+agent coexist (each keyed by its own deletion_key). Once
# production has recorded two such rows, rolling back would require re-adding the OLD 3-column
# unique index (conversation_id, prior_assignee_id, event), which those rows now violate — so the
# down would fail nondeterministically, mid-migration, only on installs that accumulated a second
# occurrence. A rollback that can leave the schema half-reverted after valid production data is
# worse than none, so we raise ActiveRecord::IrreversibleMigration instead. The forward path is
# unchanged.
class AddDeferredProvenanceDeletionKey < ActiveRecord::Migration[7.1]
  TABLE = :wijaya_deferred_assignment_provenance
  OLD_INDEX = 'idx_wijaya_deferred_prov_unique_event'.freeze
  NEW_INDEX = 'idx_wijaya_deferred_prov_unique_occurrence'.freeze

  def up
    return unless table_exists?(TABLE)

    add_column TABLE, :deletion_key, :string unless column_exists?(TABLE, :deletion_key)
    execute("UPDATE #{TABLE} SET deletion_key = 'legacy' WHERE deletion_key IS NULL")
    change_column_null TABLE, :deletion_key, false
    swap_to_occurrence_index
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Re-adding the 3-column unique index would violate distinct deletion-occurrence rows ' \
          'the 4-column index legitimately allows; rollback cannot be applied safely.'
  end

  def swap_to_occurrence_index
    remove_index TABLE, name: OLD_INDEX if index_name_exists?(TABLE, OLD_INDEX)
    return if index_name_exists?(TABLE, NEW_INDEX)

    add_index TABLE, %i[conversation_id prior_assignee_id event deletion_key],
              unique: true, name: NEW_INDEX
  end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
