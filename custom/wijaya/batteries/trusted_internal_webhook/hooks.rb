# frozen_string_literal: true

require_relative 'policy'
require_relative 'delivery'

# Native seam entry point for lib/webhooks/trigger.rb.
#
# Returns false — so the native SafeFetch delivery runs completely unchanged — for every
# webhook EXCEPT an API-inbox webhook whose destination host is explicitly allowlisted
# (see Policy). For that single case it performs the private/internal delivery (Delivery)
# and returns true, so the native path is skipped.
#
# The TRUST DECISION fails OPEN: any unexpected error while deciding is swallowed and false
# is returned, so a battery problem can never block an otherwise-deliverable public
# webhook. The DELIVERY itself fails CLOSED: once the host is trusted, a transport/HTTP
# failure is raised (as a SafeFetch error) so Webhooks::Trigger marks the message failed
# exactly as on the native path. This is precisely why the seam calls this battery directly
# instead of through the fail-open Wijaya::Batteries::Core::Hooks dispatcher: that
# dispatcher would swallow a genuine delivery error and silently fall back to a doomed
# public request against the internal host.
#
# Nested (not compact) module declaration so this file is safe to require directly from the
# native seam before any Wijaya parent constant exists.
module Wijaya
  module Batteries
    module TrustedInternalWebhook
      module Hooks
        module_function

        def deliver(url:, webhook_type:, body:, headers:, timeout:)
          return false unless trusted?(url: url, webhook_type: webhook_type)

          Delivery.new(url: url, body: body, headers: headers, timeout: timeout).perform
          true
        end

        def trusted?(url:, webhook_type:)
          Policy.trusted?(url: url, webhook_type: webhook_type)
        rescue StandardError, ScriptError => e
          log_skipped(e)
          false
        end

        def log_skipped(error)
          return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

          Rails.logger.warn("[trusted_internal_webhook] policy check skipped: #{error.class}")
        end
      end
    end
  end
end
