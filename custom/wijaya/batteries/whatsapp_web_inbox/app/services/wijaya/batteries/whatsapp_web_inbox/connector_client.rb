# frozen_string_literal: true

require 'net/http'
require 'json'
require 'erb'

# Server-only client for the WhatsApp Web connector control plane. The browser never
# reaches the connector; only this class does, and it is the single place the service
# HMAC secret is used. Every request is signed (RequestSigner), strictly timeout- and
# size-bounded, never follows redirects, requires a JSON response, and raises only
# sanitized errors — never a remote body, URL, header, or secret.
#
# Endpoints (connector contract):
#   GET    /api/sessions                      list_sessions  -> { "sessions" => [view,...] }
#   POST   /api/sessions                      create_session -> session view (201)
#   GET    /api/sessions/:id                  get_session    -> session view
#   DELETE /api/sessions/:id                  delete_session -> { "status" => "deleted" }
#   POST   /api/sessions/:id/connect          connect        -> session view
#   POST   /api/sessions/:id/reconnect        reconnect      -> session view
#   POST   /api/sessions/:id/logout           logout         -> { "status" => "logged_out" }
#   GET    /api/sessions/:id/qr               qr             -> { available:, data_url:, raw_qr: }
module Wijaya
  module Batteries
    module WhatsappWebInbox
      class ConnectorClient
        class Error < StandardError; end
        # Connector is unset/misconfigured — management must fail closed.
        class ConfigurationError < Error; end
        # Transport failure or 5xx — recoverable; callers keep a pending/error mapping.
        class ConnectorUnavailable < Error; end
        # Unexpected 4xx / malformed response — not retryable as-is.
        class ConnectorError < Error; end

        def initialize
          raise ConfigurationError, 'connector not configured' unless Config.configured?

          @base = Config.connector_uri
          @secret = Config.connector_secret
        end

        def list_sessions
          request(:get, '/api/sessions')
        end

        def get_session(session_id)
          request(:get, "/api/sessions/#{encode(session_id)}")
        end

        def create_session(payload)
          request(:post, '/api/sessions', payload: payload)
        end

        def delete_session(session_id)
          request(:delete, "/api/sessions/#{encode(session_id)}")
        end

        def connect(session_id)
          request(:post, "/api/sessions/#{encode(session_id)}/connect")
        end

        def reconnect(session_id)
          request(:post, "/api/sessions/#{encode(session_id)}/reconnect")
        end

        def logout(session_id)
          request(:post, "/api/sessions/#{encode(session_id)}/logout")
        end

        # QR is special: a 409 qr_not_available is an expected "no live QR" state, not an
        # error. Returns a sanitized hash; the raw qr string is returned here (server
        # side) but the controller NEVER forwards it to the browser.
        def qr(session_id)
          status, body = perform(:get, "/api/sessions/#{encode(session_id)}/qr")
          return { 'available' => false } if status == 409

          raise_for_status(status, body)
          { 'available' => true, 'data_url' => body['dataUrl'], 'raw_qr' => body['qr'] }
        end

        private

        def request(method, path, payload: nil)
          status, body = perform(method, path, payload: payload)
          raise_for_status(status, body)
          body
        end

        # Returns [status_integer, parsed_body_hash]. Raises ConnectorUnavailable on any
        # transport-level failure (sanitized), ConnectorError on a non-JSON/oversized
        # response.
        def perform(method, path, payload: nil)
          uri = @base.merge(path)
          raw_body = payload.nil? ? nil : JSON.generate(payload)
          req = build_request(method, uri, raw_body)
          send_request(uri, req)
        rescue Timeout::Error # covers Net::OpenTimeout / Net::ReadTimeout (subclasses)
          raise ConnectorUnavailable, 'connector request timed out'
        rescue SocketError, OpenSSL::SSL::SSLError, IOError, SystemCallError # IOError covers EOFError
          raise ConnectorUnavailable, 'connector request failed'
        end

        def build_request(method, uri, raw_body)
          klass = {
            get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete
          }.fetch(method)
          req = klass.new(uri.request_uri)
          req['Accept'] = 'application/json'
          if raw_body
            req['Content-Type'] = 'application/json'
            req.body = raw_body
          end
          RequestSigner.headers(method: method.to_s, path: uri.path, raw_body: raw_body,
                                secret: @secret).each { |name, value| req[name] = value }
          req
        end

        def send_request(uri, req)
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https',
                                                  open_timeout: Config::OPEN_TIMEOUT,
                                                  read_timeout: Config::READ_TIMEOUT,
                                                  max_retries: 0) do |http|
            # Net::HTTP#request returns the response (not the block's value) when a block
            # is given, so capture the parsed [status, body] the streaming block builds.
            result = nil
            http.request(req) { |response| result = read_response(response) }
            result
          end
        end

        # Stream the body with a hard size cap so an unexpectedly huge response can never
        # exhaust memory. Parse JSON only; a non-JSON content type is a protocol error.
        def read_response(response)
          body = read_capped_body(response)
          status = response.code.to_i
          # Non-2xx is owned by raise_for_status (5xx -> ConnectorUnavailable, other ->
          # ConnectorError) and its body — often a non-JSON proxy/error page — is never
          # used. Only a success body is parsed, and only a success body must be JSON.
          return [status, {}] unless status.between?(200, 299)
          return [status, {}] if body.empty?

          content_type = response['content-type'].to_s
          raise ConnectorError, 'unexpected connector response' unless content_type.include?('application/json')

          [status, parse_json(body)]
        end

        def read_capped_body(response)
          buffer = +''
          response.read_body do |chunk|
            buffer << chunk
            raise ConnectorError, 'connector response too large' if buffer.bytesize > Config::MAX_RESPONSE_BYTES
          end
          buffer
        end

        def parse_json(body)
          parsed = JSON.parse(body)
          raise ConnectorError, 'unexpected connector response' unless parsed.is_a?(Hash)

          parsed
        rescue JSON::ParserError
          raise ConnectorError, 'unexpected connector response'
        end

        def raise_for_status(status, _body)
          return if status.between?(200, 299)
          raise ConnectorUnavailable, 'connector temporarily unavailable' if status >= 500

          raise ConnectorError, "connector rejected request (#{status})"
        end

        # Path-segment-safe; session ids are connector-issued UUIDs but we never trust
        # that blindly when composing a URL.
        def encode(value)
          ERB::Util.url_encode(value.to_s)
        end
      end
    end
  end
end
