# frozen_string_literal: true

# Builds the ONLY shapes the browser is ever allowed to see for a WhatsApp Web mapping.
# It can never carry the connector service secret, the channel secret/hmac_token, the
# raw QR string, Baileys credentials, the full phone number/JID, or any remote response
# body. Identity (waJid) is masked to its last 4 digits.
module Wijaya
  module Batteries
    module WhatsappWebInbox
      module SafeDto
        module_function

        # record: a Record; session: optional raw connector session view (for status);
        # connector_available: whether the last connector call succeeded.
        def inbox(record, session: nil, connector_available: true)
          {
            id: record.id,
            inbox_id: record.inbox_id,
            name: record.inbox&.name,
            provisioning_state: record.provisioning_state,
            status: record.status,
            last_error_code: record.last_error_code,
            connector_available: connector_available,
            wa_jid_masked: mask_jid(session && session['waJid'])
          }
        end

        # qr_result is ConnectorClient#qr's sanitized hash; the raw qr is dropped here —
        # only the data URL is ever forwarded.
        def qr(record, qr_result, connector_available: true)
          {
            inbox_id: record.inbox_id,
            status: record.status,
            connector_available: connector_available,
            available: connector_available && qr_result.present? && qr_result['available'] == true,
            data_url: connector_available ? qr_result&.dig('data_url') : nil
          }
        end

        # "6281234567890@s.whatsapp.net" -> "••••7890"; nil/blank -> nil.
        def mask_jid(value)
          digits = value.to_s[/\A\d+/]
          return nil if digits.blank?

          "••••#{digits[-4..] || digits}"
        end
      end
    end
  end
end
