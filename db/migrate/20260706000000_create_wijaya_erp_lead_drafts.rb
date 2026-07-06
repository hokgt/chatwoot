# WIJAYA_CUSTOM_START erp_lead_sidebar
class CreateWijayaErpLeadDrafts < ActiveRecord::Migration[7.1]
  def change
    create_table :wijaya_erp_lead_drafts do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true
      t.jsonb :fields, null: false, default: {}
      t.jsonb :last_payload, null: false, default: {}
      t.string :sync_status, null: false, default: 'draft'
      t.string :erp_lead_id
      t.text :last_error

      t.timestamps
    end

    add_index :wijaya_erp_lead_drafts, %i[account_id conversation_id], unique: true,
              name: 'index_wijaya_erp_lead_drafts_on_account_conversation'
  end
end
# WIJAYA_CUSTOM_END erp_lead_sidebar
