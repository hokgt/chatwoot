class CreateWijayaMarineInboxes < ActiveRecord::Migration[7.0]
  def change
    create_table :marine_inboxes do |t|
      t.references :marine_assistant, null: false, index: false
      t.references :inbox, null: false, index: false
      t.timestamps
    end

    add_index :marine_inboxes, [:marine_assistant_id, :inbox_id], unique: true, name: 'idx_marine_inboxes_on_assistant_and_inbox'
    add_index :marine_inboxes, :inbox_id, unique: true
  end
end
