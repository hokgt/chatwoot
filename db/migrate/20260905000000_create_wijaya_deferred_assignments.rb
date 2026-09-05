# WIJAYA_CUSTOM_START deferred_auto_assignment
class CreateWijayaDeferredAssignments < ActiveRecord::Migration[7.1]
  def change
    create_table :wijaya_deferred_assignments do |t|
      t.references :account, null: false, foreign_key: true
      t.references :inbox, null: false, foreign_key: true
      # Unique per conversation: the marker is a durable record keyed uniquely by
      # conversation_id (registration is idempotent, later triggers reuse the row).
      t.references :conversation, null: false, foreign_key: true, index: { unique: true }

      t.timestamps
    end
  end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
