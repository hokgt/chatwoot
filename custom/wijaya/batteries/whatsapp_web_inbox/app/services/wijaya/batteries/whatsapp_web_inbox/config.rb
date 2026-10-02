# frozen_string_literal: true

require 'uri'
require 'ipaddr'

# Single source of truth for the server-only WhatsApp Web connector configuration.
# Every value comes from the environment — NEVER from a browser-supplied field — so no
# request can ever point Rails at an arbitrary host.
#
#   WHATSAPP_WEB_CONNECTOR_URL          control-plane origin Rails signs & calls
#   WHATSAPP_WEB_CONNECTOR_HMAC_SECRET  shared service HMAC secret (never logged/returned)
#   FRONTEND_URL                        public Chatwoot HTTPS origin given to the connector
#                                       as `baseUrl` (where it calls our public API inbox)
#
# The connector base URL is validated here (at use): https is always accepted; plain
# http is accepted ONLY for an internal/loopback host (docker service name, private IP,
# loopback) so Dev can point at the internal service, while a public http origin is
# rejected. The public base URL must be https.
module Wijaya
  module Batteries
    module WhatsappWebInbox
      module Config
        OPEN_TIMEOUT = 5
        READ_TIMEOUT = 5
        # Hard cap on any connector response body we will buffer. The connector caps
        # its own request bodies at 1 MiB; we mirror that for responses.
        MAX_RESPONSE_BYTES = 1024 * 1024

        module_function

        def connector_url
          ENV['WHATSAPP_WEB_CONNECTOR_URL'].presence
        end

        def connector_secret
          ENV['WHATSAPP_WEB_CONNECTOR_HMAC_SECRET'].presence
        end

        def public_base_url
          ENV['FRONTEND_URL'].presence
        end

        # Management operations fail closed unless the connector is fully configured and
        # both URLs validate. Boot and unrelated inboxes are never affected — this is
        # only ever consulted by the battery's own endpoints/jobs.
        def configured?
          connector_secret.present? &&
            connector_uri.present? &&
            public_base_uri.present?
        end

        # Parsed, validated control-plane URI, or nil when unset/invalid.
        def connector_uri
          uri = safe_parse(connector_url)
          return nil if uri.nil?
          return uri if uri.scheme == 'https'
          return uri if uri.scheme == 'http' && internal_host?(uri.host)

          nil
        end

        # Parsed, validated public Chatwoot origin (https only), or nil.
        def public_base_uri
          uri = safe_parse(public_base_url)
          return nil if uri.nil?

          uri.scheme == 'https' ? uri : nil
        end

        def safe_parse(value)
          return nil if value.blank?

          uri = URI.parse(value.to_s.strip)
          return nil unless uri.is_a?(URI::HTTP)
          return nil if uri.host.blank?
          return nil if uri.userinfo.present?

          uri
        rescue URI::InvalidURIError
          nil
        end

        # True for hosts that are safe to reach over plain http in Dev: loopback,
        # private IPs, and single-label / *.local / *.internal docker service names.
        # A public multi-label DNS name over http returns false.
        def internal_host?(host)
          normalized = host.to_s.downcase
          return true if normalized == 'localhost' || normalized.end_with?('.localhost', '.local', '.internal')
          return true unless normalized.include?('.') # single-label docker service name

          addr = safe_ipaddr(normalized)
          return false if addr.nil?

          addr.loopback? || addr.private? || addr.link_local?
        end

        def safe_ipaddr(value)
          IPAddr.new(value.to_s)
        rescue IPAddr::InvalidAddressError
          nil
        end
      end
    end
  end
end
