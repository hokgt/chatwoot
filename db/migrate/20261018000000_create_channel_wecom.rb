# Native WeCom / WeChat Customer Service (微信客服) channel table. A native
# Channel::Wecom is mandated (not an adapter on Channel::Api), so this migration
# necessarily lives at the standard db/migrate path. All provider/business logic
# is isolated in custom/wijaya/batteries/wecom_channel; only the thin AR model and
# this migration sit outside the battery, mirroring every other native channel
# (channel_tiktok, channel_line, ...).
#
# Credentials (secret/token/encoding_aes_key) are text columns because Active
# Record Encryption's ciphertext envelope is larger than the short plaintext.
# secret and open_kfid are nullable: the corp-scoped callback is verified with
# only token + encoding_aes_key before a Secret exists, and the Open KF ID is
# discovered afterwards. corp_id is indexed (non-unique) because a single verified
# Corp ID callback can front several KF-account inboxes; open_kfid carries a
# partial unique index so the authoritative KF account routes to exactly one inbox.
class CreateChannelWecom < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_wecom do |t|
      t.integer :account_id, null: false
      t.string :corp_id, null: false
      t.string :open_kfid
      t.text :secret
      t.text :token, null: false
      t.text :encoding_aes_key, null: false
      t.string :sync_cursor
      t.timestamps
    end

    add_index :channel_wecom, :corp_id
    add_index :channel_wecom, :open_kfid, unique: true, where: 'open_kfid IS NOT NULL'
  end
end
