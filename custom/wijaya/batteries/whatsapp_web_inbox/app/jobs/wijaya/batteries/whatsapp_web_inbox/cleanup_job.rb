# frozen_string_literal: true

# Idempotent, fire-and-forget deletion of the connector session after the local
# mapping/inbox has already been deleted. A connector outage retries with backoff; an
# unconfigured connector or an already-gone/invalid session is swallowed (sanitized) so
# a non-recoverable condition never retries forever. Remote failure never blocks local
# deletion — that already committed before this job runs.
module Wijaya
  module Batteries
    module WhatsappWebInbox
      class CleanupJob < ApplicationJob
        queue_as :default

        retry_on ConnectorClient::ConnectorUnavailable, wait: :polynomially_longer, attempts: 5

        def perform(connector_session_id:)
          return if connector_session_id.blank?

          ConnectorClient.new.delete_session(connector_session_id)
        rescue ConnectorClient::ConfigurationError, ConnectorClient::ConnectorError
          nil
        end
      end
    end
  end
end
