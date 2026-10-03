# frozen_string_literal: true

# Durable, per-inbox mapping between a native Channel::Api inbox and its WhatsApp Web
# (unofficial, Baileys) connector session. One row per inbox, keyed uniquely by
# inbox_id; the client-supplied request_token makes creation idempotent per account
# (the token is unique within an account, so two accounts may reuse the same value).
#
# This row deliberately stores ONLY sanitized lifecycle metadata. It never holds the
# connector service secret, the raw QR, Baileys credentials, the Chatwoot channel
# secret / hmac_token, the phone number, or any message content — those live only on
# the Channel::Api row (encrypted) or on the connector, and are never mirrored here.
module Wijaya
  module Batteries
    module WhatsappWebInbox
      class Record < ApplicationRecord
        self.table_name = 'wijaya_whatsapp_web_inboxes'

        # The stable namespaced marker written onto Channel::Api#additional_attributes so
        # both backend and frontend can recognise a WhatsApp Web inbox generically.
        PROVIDER = 'whatsapp_web'
        ADDITIONAL_ATTRIBUTES_KEY = 'wijaya_provider'

        # Durable mapping lifecycle, independent of the remote session status.
        PROVISIONING_PENDING = 'pending'
        PROVISIONING_PROVISIONED = 'provisioned'
        PROVISIONING_ERROR = 'error'
        PROVISIONING_STATES = [PROVISIONING_PENDING, PROVISIONING_PROVISIONED, PROVISIONING_ERROR].freeze

        # The connector's own session status union (mirrored, sanitized). Any value
        # outside this set is coerced to 'error' before it is ever stored or rendered.
        STATUSES = %w[
          unconfigured waiting_for_qr connecting connected
          disconnected logged_out authentication_failed replaced error
        ].freeze

        belongs_to :account
        belongs_to :inbox

        validates :inbox_id, uniqueness: true
        validates :request_token, presence: true, uniqueness: { scope: :account_id }
        validates :provisioning_state, inclusion: { in: PROVISIONING_STATES }
        validates :status, inclusion: { in: STATUSES }

        # Fire-and-forget remote cleanup on local deletion. Enqueued after commit so a
        # rolled-back destroy never triggers a remote delete; a no-op when the session
        # was never provisioned. The job is idempotent and bounded-retry, so a remote
        # failure never blocks (already-committed) local deletion.
        after_destroy_commit :enqueue_connector_cleanup

        # Coerce any connector-reported status into the known set so an unexpected
        # remote value can never be persisted/rendered verbatim.
        def self.sanitize_status(value)
          STATUSES.include?(value.to_s) ? value.to_s : 'error'
        end

        def provisioned?
          provisioning_state == PROVISIONING_PROVISIONED
        end

        private

        def enqueue_connector_cleanup
          return if connector_session_id.blank?

          CleanupJob.perform_later(connector_session_id: connector_session_id)
        end
      end
    end
  end
end
