class CreateMarineScenarios < ActiveRecord::Migration[7.0]
  def change
    create_table :marine_scenarios do |t|
      t.string :title
      t.text :description
      t.text :instruction
      t.jsonb :tools, default: []
      t.boolean :enabled, default: true, null: false
      t.references :assistant, null: false, index: true
      t.references :account, null: false, index: true

      t.timestamps
    end

    add_index :marine_scenarios, :enabled
    add_index :marine_scenarios, [:assistant_id, :enabled]
  end
end
