# WIJAYA_CUSTOM_START meta_ads_team_routing
class CreateWijayaMetaAdsTeamRoutingRules < ActiveRecord::Migration[7.0]
  def change
    create_table :wijaya_meta_ads_team_routing_rules do |t|
      t.references :account, null: false, foreign_key: true
      t.references :team, null: false, foreign_key: true
      t.string :source_id, null: false
      t.string :campaign_name
      t.integer :status, null: false, default: 1

      t.timestamps
    end

    add_index :wijaya_meta_ads_team_routing_rules, %i[account_id source_id],
              unique: true, name: 'index_wijaya_meta_ads_routing_on_account_and_source'
  end
end
# WIJAYA_CUSTOM_END meta_ads_team_routing
