# frozen_string_literal: true

# Durable, idempotent provisioning of a WhatsApp Web inbox. The fragile external call
# is kept OUT of the DB transaction:
#
#   create!  — in ONE transaction creates the Channel::Api (hmac_mandatory, provider
#              marker), the Inbox, and the pending mapping keyed by the client request
#              token. No network here. A duplicate request token returns the existing
#              mapping (never a second inbox).
#   provision_session! — runs AFTER commit (from ProvisionJob). It reconciles first
#              (signed list/get by exact inboxIdentifier) so an ambiguous earlier create
#              is adopted rather than duplicated, creates the session only if none
#              exists, sets the channel webhook_url to the connector callback ONLY once a
#              session id exists, and marks the mapping provisioned. A connector outage
#              leaves a recoverable error mapping (the inbox is never deleted) that the
#              retry endpoint/job can resume.
module Wijaya
  module Batteries
    module WhatsappWebInbox
      class Provisioner
        def self.create!(account:, name:, request_token:)
          new(account: account).create!(name: name, request_token: request_token)
        end

        def initialize(account:)
          @account = account
        end

        # Create (or return the existing) mapping, then enqueue post-commit provisioning.
        def create!(name:, request_token:)
          existing = Record.find_by(request_token: request_token)
          return reuse(existing) if existing

          record = build_in_transaction(name: name, request_token: request_token)
          ProvisionJob.perform_later(record_id: record.id)
          record
        rescue ActiveRecord::RecordNotUnique
          # Lost a concurrent race on the unique request_token: reuse the winner.
          reuse(Record.find_by!(request_token: request_token))
        end

        # Idempotent: adopt an existing session, else reconcile, else create. Marks the
        # mapping provisioned only after a session id exists and the webhook is set.
        def provision_session!(record)
          client = ConnectorClient.new
          session = resolve_session(client, record)
          session_id = session['id'].to_s
          raise ConnectorClient::ConnectorError, 'missing session id' if session_id.blank?

          set_webhook_url(record, session_id)
          record.update!(connector_session_id: session_id,
                         provisioning_state: Record::PROVISIONING_PROVISIONED,
                         status: Record.sanitize_status(session['status']),
                         last_error_code: nil)
          record
        rescue ConnectorClient::ConfigurationError
          mark_error(record, 'connector_not_configured')
          nil
        rescue ConnectorClient::ConnectorError
          mark_error(record, 'connector_error')
          nil
        rescue ConnectorClient::ConnectorUnavailable
          mark_error(record, 'connector_unavailable')
          raise # recoverable — let the job retry
        end

        private

        attr_reader :account

        def reuse(record)
          record.account_id == account.id ? record : nil
        end

        def build_in_transaction(name:, request_token:)
          ActiveRecord::Base.transaction do
            channel = account.api_channels.create!(
              hmac_mandatory: true,
              additional_attributes: { Record::ADDITIONAL_ATTRIBUTES_KEY => Record::PROVIDER }
            )
            inbox = account.inboxes.create!(name: name, channel: channel)
            Record.create!(account: account, inbox: inbox, request_token: request_token,
                           provisioning_state: Record::PROVISIONING_PENDING,
                           status: 'unconfigured')
          end
        end

        # Adopt a session this mapping already points at, else find one the connector
        # already holds for this exact inboxIdentifier/account (ambiguous-create
        # recovery), else create a fresh session.
        def resolve_session(client, record)
          return client.get_session(record.connector_session_id) if record.connector_session_id.present?

          find_existing_session(client, record) || client.create_session(create_payload(record))
        end

        def find_existing_session(client, record)
          identifier = record.inbox.channel.identifier
          sessions = client.list_sessions['sessions']
          return nil unless sessions.is_a?(Array)

          sessions.find do |session|
            session.dig('chatwoot', 'inboxIdentifier') == identifier &&
              session.dig('chatwoot', 'accountId') == record.account_id
          end
        end

        def create_payload(record)
          channel = record.inbox.channel
          {
            baseUrl: Config.public_base_url,
            accountId: record.account_id,
            inboxIdentifier: channel.identifier,
            hmacMandatory: true,
            hmacToken: channel.hmac_token,
            webhookSecret: channel.secret
          }
        end

        def set_webhook_url(record, session_id)
          url = "#{Config.connector_url.chomp('/')}/webhooks/chatwoot/#{session_id}"
          record.inbox.channel.update!(webhook_url: url)
        end

        def mark_error(record, code)
          record.update!(provisioning_state: Record::PROVISIONING_ERROR, last_error_code: code)
        end
      end
    end
  end
end
