# frozen_string_literal: true

require 'uri'

# Default-deny security boundary for trusted internal webhook delivery.
#
# Only the API-inbox webhook delivery path may ever reach a private/internal host, and
# only when the destination host is EXPLICITLY trusted. The trusted set is entirely
# configuration-driven, from two sources that each default to empty:
#
#   * the configured WhatsApp Web connector host (WHATSAPP_WEB_CONNECTOR_URL) — the exact
#     host the connector's own `/webhooks/chatwoot/<id>` callback URL is built from
#     (see WhatsappWebInbox::Provisioner#set_webhook_url); and
#   * any host listed in WIJAYA_TRUSTED_INTERNAL_WEBHOOK_HOSTS (comma-separated).
#
# With no configuration NOTHING is trusted, so the native SafeFetch/SsrfFilter path is
# used unchanged for every webhook. Membership is exact and case-insensitive on the
# parsed URI host only; a URL carrying userinfo (user:pass@host) is rejected outright, so
# `trusted-host@evil`, `evil@trusted-host`, case tricks, and suffix tricks
# (`trusted-host.evil`) can never match an allowlisted entry nor widen access to an
# arbitrary RFC1918 target.
#
# Nested (not compact) module declaration so this file is safe to require directly from
# the native lib/webhooks/trigger.rb seam before any Wijaya parent constant exists.
module Wijaya
  module Batteries
    module TrustedInternalWebhook
      module Policy
        ENV_ALLOWLIST_KEY = 'WIJAYA_TRUSTED_INTERNAL_WEBHOOK_HOSTS'

        module_function

        # True ONLY for an API-inbox webhook whose destination host is allowlisted.
        def trusted?(url:, webhook_type:)
          return false unless webhook_type == :api_inbox_webhook

          host = request_host(url)
          return false if host.blank?

          allowed_hosts.include?(host)
        end

        # The normalized (stripped, lower-cased, de-duplicated) set of trusted hosts.
        def allowed_hosts
          (connector_hosts + explicit_hosts).filter_map do |value|
            normalized = value.to_s.strip.downcase
            normalized unless normalized.empty?
          end.uniq
        end

        # The WhatsApp Web connector host, derived from the already-validated connector
        # URI (https, or http only for an internal host). Any absence/error — including the
        # battery not being loaded (NameError) — yields no trusted host (default-deny).
        def connector_hosts
          host = Wijaya::Batteries::WhatsappWebInbox::Config.connector_uri&.host
          host ? [host] : []
        rescue StandardError, ScriptError
          []
        end

        def explicit_hosts
          ENV.fetch(ENV_ALLOWLIST_KEY, '').split(',')
        end

        # Lower-cased host ONLY for a well-formed http(s) URL with NO userinfo; otherwise nil.
        def request_host(url)
          uri = URI.parse(url.to_s)
          return nil unless uri.is_a?(URI::HTTP)
          return nil if uri.userinfo
          return nil if uri.host.blank?

          uri.host.downcase
        rescue URI::InvalidURIError
          nil
        end
      end
    end
  end
end
