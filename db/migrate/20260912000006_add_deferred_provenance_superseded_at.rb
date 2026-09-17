# WIJAYA_CUSTOM_START deferred_auto_assignment
# Causal-continuity guard column for the provenance tombstone.
#
# A tombstone records that an agent deletion cleared a conversation's human assignee. The
# reconciliation may only adopt it if the conversation is STILL causally the deletion's orphan.
# Depending only on "current assignee is nil" is insufficient: a conversation manually (or by bot,
# or by team/inbox routing, or by close→reopen) reassigned AFTER the deletion and THEN unassigned
# again is open + assignee-nil once more, yet its emptiness no longer traces to the deletion — the
# intervening intentional transition broke the causal chain, so it must NEVER be re-adopted.
#
# superseded_at is stamped, transactionally and atomically, by the battery ConversationExtensions
# in-transaction after_update seam the instant such an intervening transition commits. The
# reconciliation's `unreconciled` scope excludes superseded rows, so a superseded tombstone is never
# scanned or adopted. The deletion-caused unassignment itself uses update_all (callbacks skipped),
# so it never supersedes its own tombstone and a genuine crash-gap orphan stays eligible.
#
# Forward-only additive column; NULL for every existing row (none superseded yet), so all prior
# tombstones are unchanged.
class AddDeferredProvenanceSupersededAt < ActiveRecord::Migration[7.1]
  TABLE = :wijaya_deferred_assignment_provenance

  def up
    return unless table_exists?(TABLE)

    add_column TABLE, :superseded_at, :datetime unless column_exists?(TABLE, :superseded_at)
    return if index_name_exists?(TABLE, 'idx_wijaya_deferred_prov_on_superseded_at')

    add_index TABLE, :superseded_at, name: 'idx_wijaya_deferred_prov_on_superseded_at'
  end

  def down
    return unless table_exists?(TABLE)

    remove_index TABLE, name: 'idx_wijaya_deferred_prov_on_superseded_at' if index_name_exists?(TABLE, 'idx_wijaya_deferred_prov_on_superseded_at')
    remove_column TABLE, :superseded_at if column_exists?(TABLE, :superseded_at)
  end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
