# frozen_string_literal: true

require 'net/http'
require 'uri'

# Minimal single-request POST delivery for a trusted internal webhook host.
#
# This is the ONLY place the API-inbox webhook delivery path is allowed to reach a
# private/internal host, and it is reached ONLY after Policy has confirmed the destination
# host is explicitly allowlisted. It deliberately performs EXACTLY ONE request and follows
# NO redirects — a 3xx is surfaced as a SafeFetch::HttpError, never followed — so a
# misbehaving or compromised connector can never bounce the signed payload onward to an
# arbitrary RFC1918 target. The signed HMAC headers, JSON body, and per-request open/read
# timeouts are passed through verbatim from Webhooks::Trigger, and failures are re-raised
# as the SafeFetch error classes the native trigger already understands, so message-status
# handling and logging behave exactly as they do on the public SafeFetch path.
#
# Nested (not compact) module declaration so this file is safe to require directly from the
# native lib/webhooks/trigger.rb seam before any Wijaya parent constant exists.
module Wijaya
  module Batteries
    module TrustedInternalWebhook
      class Delivery
        TRANSPORT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError, SystemCallError].freeze

        def initialize(url:, body:, headers:, timeout:)
          @uri = URI.parse(url.to_s)
          @body = body
          @headers = headers || {}
          @timeout = timeout
        end

        # Returns nil on a 2xx response (mirrors the native SafeFetch block result); raises
        # SafeFetch::HttpError on any non-success (including a never-followed redirect) and
        # SafeFetch::FetchError on a transport failure.
        def perform
          response = request!
          return if response.is_a?(Net::HTTPSuccess)

          raise SafeFetch::HttpError, "#{response.code} #{response.message}"
        rescue *TRANSPORT_ERRORS => e
          raise SafeFetch::FetchError, e.message
        end

        private

        def request!
          http = Net::HTTP.new(@uri.host, @uri.port)
          http.use_ssl = @uri.scheme == 'https'
          http.open_timeout = @timeout
          http.read_timeout = @timeout

          request = Net::HTTP::Post.new(request_uri)
          @headers.each { |name, value| request[name] = value }
          request.body = @body

          http.request(request)
        end

        def request_uri
          path = @uri.path
          path = '/' if path.blank?
          @uri.query ? "#{path}?#{@uri.query}" : path
        end
      end
    end
  end
end
