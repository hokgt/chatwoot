# WIJAYA_CUSTOM_START deferred_auto_assignment
# Forward-only repair of the wijaya_deferred_assignments (marker) foreign keys to on_delete: :cascade.
#
# The original 20260905000000 migration was later edited in place to declare on_delete: :cascade on
# its account/inbox/conversation FKs. Editing an already-applied migration does NOT change the live
# database: any environment that applied 20260905000000 BEFORE that edit still carries NO ACTION FKs,
# so schema.rb (which expects cascade) and the live upgrade path have drifted. A conversation deleted
# via a path that bypasses the has_one dependent: :destroy (e.g. account.conversations.delete_all)
# would then raise a foreign-key violation instead of cascading the marker away.
#
# This migration reconciles the drift the correct way — a NEW forward migration, never a history
# rewrite — by replacing ONLY those three marker FKs with the intended cascade semantics. It is
# idempotent (remove-if-exists then add) and touches no unrelated constraint or data. On an
# environment that already has cascade (schema.rb-fresh installs) it simply re-establishes the
# identical cascade FK, a no-op in effect.
class RepairWijayaDeferredAssignmentMarkerFks < ActiveRecord::Migration[7.1]
  TABLE = :wijaya_deferred_assignments
  PARENTS = %i[accounts inboxes conversations].freeze

  def up
    return unless table_exists?(TABLE)

    PARENTS.each { |parent| replace_cascade_fk(parent) }
  end

  # Intended state is cascade; reverse is a no-op (we never want to reintroduce the drifted NO ACTION).
  def down; end

  def replace_cascade_fk(parent)
    remove_foreign_key TABLE, parent if foreign_key_exists?(TABLE, parent)
    add_foreign_key TABLE, parent, on_delete: :cascade
  end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
