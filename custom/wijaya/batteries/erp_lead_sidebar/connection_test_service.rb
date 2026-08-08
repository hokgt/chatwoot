# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

# Validates a set of ERPNext credentials before/while an admin saves them. Performs
# a single minimal authenticated Frappe request (`frappe.auth.get_logged_user`,
# which just echoes the authenticated user) with a strict timeout, then normalizes
# the outcome into a sanitized result hash. Redirects are never followed (Net::HTTP
# does not follow them). The API key/secret are never placed in the result or logs.
#
#   { ok:, message:, error: }
# rubocop:disable Style/ClassAndModuleChildren -- nested style preserves sibling constant resolution
module Wijaya::Batteries::ErpLeadSidebar
  class ConnectionTestService
    TEST_TIMEOUT = 5
    PING_PATH = '/api/method/frappe.auth.get_logged_user'

    def initialize(host:, api_key:, api_secret:)
      @host = HostValidator.normalize(host.to_s)
      @api_key = api_key.to_s
      @api_secret = api_secret.to_s
    end

    def call
      shape_error = HostValidator.error_for(@host)
      return failure("Host #{shape_error}") if shape_error
      return failure('API key is required') if @api_key.blank?
      return failure('Secret key is required') if @api_secret.blank?

      uri = URI.parse("#{@host}#{PING_PATH}")
      interpret(request(uri))
    rescue SafeHttp::TimeoutError
      failure('Connection timed out')
    rescue StandardError
      # Never surface the raw transport/ERPNext exception to the admin.
      failure('Could not connect to ERPNext')
    end

    private

    def request(uri)
      SafeHttp.request(method: :get, uri: uri, api_key: @api_key, api_secret: @api_secret)
    end

    def interpret(response)
      case response
      when Net::HTTPSuccess
        success('Connected to ERPNext successfully.')
      when Net::HTTPUnauthorized, Net::HTTPForbidden
        failure('Authentication failed. Check the API key and secret.')
      when Net::HTTPNotFound
        failure('ERPNext endpoint not found. Check the host.')
      else
        failure("ERPNext returned an unexpected response (#{response.code}).")
      end
    end

    def success(message)
      { ok: true, message: message, error: nil }
    end

    def failure(error)
      { ok: false, message: nil, error: error }
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
