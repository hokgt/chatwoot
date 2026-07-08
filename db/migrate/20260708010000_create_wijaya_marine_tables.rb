class CreateWijayaMarineTables < ActiveRecord::Migration[7.0]
  def up
    setup_vector_extension
    create_marine_assistants
    create_marine_documents
    create_marine_assistant_responses
  end

  def down
    drop_table :marine_assistant_responses if table_exists?(:marine_assistant_responses)
    drop_table :marine_documents if table_exists?(:marine_documents)
    drop_table :marine_assistants if table_exists?(:marine_assistants)
  end

  private

  def setup_vector_extension
    return if extension_enabled?('vector')

    enable_extension 'vector'
  rescue ActiveRecord::StatementInvalid
    raise StandardError, "Failed to enable 'vector' extension required by Marine AI"
  end

  def create_marine_assistants
    create_table :marine_assistants do |t|
      t.string :name, null: false
      t.bigint :account_id, null: false
      t.string :description
      t.jsonb :config, default: {}, null: false
      t.jsonb :guardrails
      t.jsonb :response_guidelines
      t.timestamps
    end

    add_index :marine_assistants, :account_id
  end

  def create_marine_documents
    create_table :marine_documents do |t|
      t.string :name
      t.text :external_link, null: false
      t.text :content
      t.bigint :assistant_id, null: false
      t.bigint :account_id, null: false
      t.integer :status, null: false, default: 0
      t.integer :sync_status
      t.datetime :last_synced_at
      t.datetime :last_sync_attempted_at
      t.jsonb :metadata, default: {}
      t.timestamps
    end

    add_index :marine_documents, :account_id
    add_index :marine_documents, :assistant_id
    add_index :marine_documents, :status
    add_index :marine_documents, [:account_id, :sync_status]
    add_index :marine_documents, 'assistant_id, md5(external_link)', unique: true, name: 'idx_marine_documents_on_assistant_id_and_external_link_md5'
    add_index :marine_documents, [:account_id, :assistant_id, :sync_status, :last_synced_at], name: 'idx_marine_documents_on_account_assistant_sync_stats'
  end

  def create_marine_assistant_responses
    create_table :marine_assistant_responses do |t|
      t.string :question, null: false
      t.text :answer, null: false
      t.vector :embedding, limit: 1536
      t.bigint :assistant_id, null: false
      t.bigint :account_id, null: false
      t.bigint :documentable_id
      t.string :documentable_type
      t.integer :status, default: 1, null: false
      t.boolean :edited, default: false, null: false
      t.timestamps
    end

    add_index :marine_assistant_responses, :account_id
    add_index :marine_assistant_responses, :assistant_id
    add_index :marine_assistant_responses, :status
    add_index :marine_assistant_responses, [:documentable_id, :documentable_type], name: 'idx_marine_asst_resp_on_documentable'
    add_index :marine_assistant_responses, :embedding, using: :ivfflat, name: 'vector_idx_marine_knowledge_entries_embedding', opclass: :vector_l2_ops
  end
end
