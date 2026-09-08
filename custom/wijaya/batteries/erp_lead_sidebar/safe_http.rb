# frozen_string_literal: true

require 'net/http'
require 'ssrf_filter'

# Shared credentialed ERPNext transport. Public hosts use ssrf_filter, which
# pins the connection to an already-validated public IP and prevents DNS
# rebinding. Redirects are returned (never followed). Only explicit loopback
# development hosts use direct Net::HTTP.
# rubocop:disable Style/ClassAndModuleChildren -- nested style preserves sibling constant resolution
module Wijaya::Batteries::ErpLeadSidebar
  module SafeHttp
    TIMEOUT = 5

    class Error < SyncError; end
    class TimeoutError < Error; end

    module_function

    def request(method:, uri:, api_key:, api_secret:, body: nil)
      headers = { 'Authorization' => "token #{api_key}:#{api_secret}" }
      headers['Content-Type'] = 'application/json' if body

      if HostValidator.local_host?(uri.hostname)
        request_local(method: method, uri: uri, headers: headers, body: body)
      else
        request_public(method: method, uri: uri, headers: headers, body: body)
      end
    rescue Timeout::Error
      raise TimeoutError, 'ERPNext request timed out'
    rescue SsrfFilter::Error, SocketError, OpenSSL::SSL::SSLError, IOError, SystemCallError
      raise Error, 'ERPNext request failed'
    end

    def request_public(method:, uri:, headers:, body:)
      SsrfFilter.public_send(
        method,
        uri.to_s,
        headers: headers,
        body: body,
        max_redirects: 0,
        allow_unfollowed_redirects: true,
        sensitive_headers: ['authorization'],
        http_options: { open_timeout: TIMEOUT, read_timeout: TIMEOUT }
      )
    end

    def request_local(method:, uri:, headers:, body:)
      request_class = SsrfFilter::VERB_MAP.fetch(method)
      request = request_class.new(uri)
      headers.each { |name, value| request[name] = value }
      request.body = body if body

      Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == 'https',
        open_timeout: TIMEOUT,
        read_timeout: TIMEOUT
      ) { |http| http.request(request) }
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
