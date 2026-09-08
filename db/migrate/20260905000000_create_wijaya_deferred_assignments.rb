# WIJAYA_CUSTOM_START deferred_auto_assignment
class CreateWijayaDeferredAssignments < ActiveRecord::Migration[7.1]
  def change
    # on_delete: :cascade on every parent FK so destroying an account, inbox, or conversation
    # (core deletes conversations via destroy_async / delete_all, which can bypass the
    # has_one dependent: :destroy) removes the child marker at the DB level instead of raising
    # a foreign-key violation. Reversible: create_table drops the table and its FKs on rollback.
    create_table :wijaya_deferred_assignments do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :inbox, null: false, foreign_key: { on_delete: :cascade }
      # Unique per conversation: the marker is a durable record keyed uniquely by
      # conversation_id (registration is idempotent, later triggers reuse the row).
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }

      t.timestamps
    end
  end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
