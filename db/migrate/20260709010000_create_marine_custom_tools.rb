class CreateMarineCustomTools < ActiveRecord::Migration[7.0]
  def change
    create_table :marine_custom_tools do |t|
      t.references :account, null: false, index: true
      t.string :slug, null: false
      t.string :title, null: false
      t.text :description
      t.string :http_method, null: false, default: 'GET'
      t.text :endpoint_url, null: false
      t.text :request_template
      t.text :response_template
      t.string :auth_type, default: 'none'
      t.jsonb :auth_config, default: {}
      t.jsonb :param_schema, default: []
      t.boolean :enabled, default: true, null: false

      t.timestamps
    end

    add_index :marine_custom_tools, [:account_id, :slug], unique: true
  end
end
