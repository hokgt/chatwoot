# frozen_string_literal: true

# Builds the ONLY shapes the browser is ever allowed to see for a WhatsApp Web mapping.
# It can never carry the connector service secret, the channel secret/hmac_token, the
# raw QR string, Baileys credentials, the full phone number/JID, or any remote response
# body. Identity (waJid) is masked to its last 4 digits.
module Wijaya
  module Batteries
    module WhatsappWebInbox
      module SafeDto
        # The ONLY data-URL shape the browser is allowed to render: a base64 PNG. A QR
        # data URL for a 512x512 PNG is a few KiB; this ceiling (256 KiB) stays far above
        # that while rejecting anything abusively large. Anything that is not an exact
        # base64 PNG data URL within the cap is dropped (treated as unavailable).
        QR_DATA_URL_PREFIX = 'data:image/png;base64,'
        MAX_QR_DATA_URL_BYTES = 256 * 1024

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
          data_url = connector_available ? safe_data_url(qr_result&.dig('data_url')) : nil
          {
            inbox_id: record.inbox_id,
            status: record.status,
            connector_available: connector_available,
            available: connector_available && qr_result.present? && qr_result['available'] == true && data_url.present?,
            data_url: data_url
          }
        end

        # Bounded, format-checked passthrough: a value is forwarded only when it is an
        # exact base64 PNG data URL within the size cap. Anything else -> nil (so the
        # DTO reports unavailable rather than binding an unexpected string into an <img>).
        def safe_data_url(value)
          return nil unless value.is_a?(String)
          return nil unless value.start_with?(QR_DATA_URL_PREFIX)
          return nil if value.bytesize > MAX_QR_DATA_URL_BYTES

          payload = value[QR_DATA_URL_PREFIX.length..]
          return nil if payload.blank?
          return nil unless payload.match?(%r{\A[A-Za-z0-9+/]+={0,2}\z})

          value
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
