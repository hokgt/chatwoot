class CreateMarineCopilotTables < ActiveRecord::Migration[7.0]
  def up
    create_marine_copilot_threads
    create_marine_copilot_messages
  end

  def down
    drop_table :marine_copilot_messages if table_exists?(:marine_copilot_messages)
    drop_table :marine_copilot_threads if table_exists?(:marine_copilot_threads)
  end

  private

  def create_marine_copilot_threads
    create_table :marine_copilot_threads do |t|
      t.string :title, null: false
      t.bigint :account_id, null: false
      t.bigint :assistant_id, null: false
      t.bigint :user_id, null: false
      t.timestamps
    end

    add_index :marine_copilot_threads, :account_id
    add_index :marine_copilot_threads, :assistant_id
    add_index :marine_copilot_threads, :user_id
  end

  def create_marine_copilot_messages
    create_table :marine_copilot_messages do |t|
      t.jsonb :message, null: false, default: {}
      t.integer :message_type, null: false, default: 0
      t.bigint :account_id, null: false
      t.bigint :copilot_thread_id, null: false
      t.timestamps
    end

    add_index :marine_copilot_messages, :account_id
    add_index :marine_copilot_messages, :copilot_thread_id
  end
end
