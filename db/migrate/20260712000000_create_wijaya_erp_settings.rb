# WIJAYA_CUSTOM_START erp_lead_sidebar
class CreateWijayaErpSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :wijaya_erp_settings do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.string :host
      # API key/secret are stored as ActiveRecord-encrypted ciphertext (text so the
      # encrypted payload always fits); never as plaintext.
      t.text :api_key
      t.text :api_secret

      t.timestamps
    end
  end
end
# WIJAYA_CUSTOM_END erp_lead_sidebar
