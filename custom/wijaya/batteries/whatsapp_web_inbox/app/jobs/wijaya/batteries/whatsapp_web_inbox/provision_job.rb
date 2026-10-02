# frozen_string_literal: true

# Post-commit provisioning of the connector session for a freshly created (or
# retried) mapping. Durable and bounded-retry: a connector outage re-raises
# ConnectorUnavailable so ActiveJob retries with backoff, while a non-recoverable
# configuration/protocol error is already folded into an error mapping by the
# Provisioner (returns nil) and must not retry. The inbox is never deleted on failure.
module Wijaya
  module Batteries
    module WhatsappWebInbox
      class ProvisionJob < ApplicationJob
        queue_as :default

        retry_on ConnectorClient::ConnectorUnavailable, wait: :polynomially_longer, attempts: 5

        def perform(record_id:)
          record = Record.find_by(id: record_id)
          return if record.nil?

          Provisioner.new(account: record.account).provision_session!(record)
        end
      end
    end
  end
end
