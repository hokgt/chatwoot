# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module Wijaya
  module Batteries
    module ErpLeadSidebar
      class SyncService
        def initialize(draft)
          @draft = draft
        end

        def perform
          raise SyncError, 'ERPNext connection is not configured' unless Config.erp_configured?

          payload = PayloadBuilder.new(@draft.fields).payload
          response = post_payload(payload)
          body = parse_body(response.body)

          unless response.is_a?(Net::HTTPSuccess)
            message = body.dig('exception') || body.dig('exc') || body.dig('message') || response.message
            raise SyncError, "ERPNext sync failed: #{message}"
          end

          lead_name = extract_lead_name(body)
          raise SyncError, 'ERPNext response did not include Lead name' if lead_name.blank?

          @draft.update!(erp_lead_id: lead_name, sync_status: 'synced', last_error: nil, last_payload: payload)
          { erp_lead_id: lead_name, payload: payload }
        end

        private

        def post_payload(payload)
          uri = URI.join(Config.erp_base_url.chomp('/') + '/', 'api/resource/Lead')
          request = Net::HTTP::Post.new(uri)
          request['Content-Type'] = 'application/json'
          request['Authorization'] = "token #{Config.erp_api_key}:#{Config.erp_api_secret}"
          request.body = payload.to_json

          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
            http.request(request)
          end
        end

        def parse_body(raw)
          JSON.parse(raw.presence || '{}')
        rescue JSON::ParserError
          {}
        end

        def extract_lead_name(body)
          return unless body.is_a?(Hash)

          data = body['data']
          return data['name'] if data.is_a?(Hash) && data['name'].present?

          message = body['message']
          return message['name'] if message.is_a?(Hash) && message['name'].present?

          body['name']
        end
      end

      class SyncError < StandardError; end
    end
  end
end
