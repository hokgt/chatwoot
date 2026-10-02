# WIJAYA_CUSTOM_START whatsapp_web_inbox
# Durable, per-inbox mapping between a native Channel::Api inbox and its WhatsApp Web
# (Baileys, unofficial) connector session. One row per inbox. The row carries only
# sanitized lifecycle metadata — NEVER the connector service secret, raw QR, Baileys
# credentials, the Chatwoot channel secret/hmac_token, the phone number, or message
# content. Every parent FK is on_delete: :cascade because core deletes inboxes via
# DeleteObjectJob (#destroy!) but may also delete_all; the cascade guarantees the
# child mapping cannot outlive its inbox/account. The Ruby has_one dependent: :destroy
# (attached by the battery InboxExtensions concern) is the primary path that fires the
# connector-session cleanup job; the cascade is the DB-level safety net.
class CreateWijayaWhatsappWebInboxes < ActiveRecord::Migration[7.1]
  def change
    create_table :wijaya_whatsapp_web_inboxes do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      # Exactly one mapping per inbox.
      t.references :inbox, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }

      # The connector-assigned session UUID. Unique, but nullable while provisioning
      # (the row exists before the connector session does). A partial unique index so
      # many pending (NULL) rows never collide but a real id is globally unique.
      t.string :connector_session_id
      # Client-generated idempotency key: a duplicate create request with the same
      # token (within the SAME account) returns/reuses the existing mapping instead of
      # provisioning twice. Scoped per account — two accounts may reuse the same value.
      t.string :request_token, null: false

      # Durable mapping lifecycle, independent of the remote session status:
      #   pending | provisioned | error  (see Record::PROVISIONING_STATES)
      t.string :provisioning_state, null: false, default: 'pending'
      # Last known connector session status, sanitized to the known state set
      # (Record::STATUSES). Defaults to the connector's own initial state.
      t.string :status, null: false, default: 'unconfigured'
      # Sanitized machine code only (e.g. 'connector_unavailable') — never a remote
      # response body or secret.
      t.string :last_error_code

      t.timestamps
    end

    add_index :wijaya_whatsapp_web_inboxes, %i[account_id request_token],
              unique: true, name: 'idx_wijaya_wa_web_inboxes_account_request_token'
    add_index :wijaya_whatsapp_web_inboxes, :connector_session_id,
              unique: true, where: 'connector_session_id IS NOT NULL'
  end
end
# WIJAYA_CUSTOM_END whatsapp_web_inbox
