# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'erb'

module Wijaya
  module Batteries
    module ErpLeadSidebar
      # Reads select-option values from ERPNext for the Lead sidebar dropdowns.
      #
      # Each dropdown (Source, Campaign, Territory, Industry) is populated from the
      # `name` of documents in a specific ERPNext DocType (see Config::OPTION_DOCTYPES).
      # Frappe exposes these via GET /api/resource/:doctype. Auth reuses the same
      # server-side token as SyncService so the API secret never reaches the browser.
      class OptionsService
        FIELDS = '["name"]'
        ORDER_BY = 'name asc'
        # Frappe treats limit_page_length=0 as "return every record".
        LIMIT_PAGE_LENGTH = 0

        # Returns { 'utm_source' => [...], 'utm_campaign' => [...], ... } keyed by
        # the Chatwoot draft field, with each value a sorted list of ERP names.
        def fetch_all
          raise SyncError, 'ERPNext connection is not configured' unless Config.erp_configured?

          Config::OPTION_DOCTYPES.to_h do |field, doctype|
            [field, fetch_names(doctype)]
          rescue SyncError => e
            Rails.logger.warn("Wijaya ERP Lead options fetch skipped for #{doctype}: #{e.message}") if defined?(Rails)
            [field, []]
          end
        end

        private

        def fetch_names(doctype)
          response = get_list(doctype)
          body = parse_body(response.body)

          unless response.is_a?(Net::HTTPSuccess)
            message = body['exception'] || body['exc'] || body['message'] || response.message
            raise SyncError, "ERPNext options fetch failed for #{doctype}: #{message}"
          end

          Array(body['data']).filter_map { |row| row['name'] if row.is_a?(Hash) }
        end

        def get_list(doctype)
          uri = list_uri(doctype)
          request = Net::HTTP::Get.new(uri)
          request['Authorization'] = "token #{Config.erp_api_key}:#{Config.erp_api_secret}"

          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
            http.request(request)
          end
        end

        def list_uri(doctype)
          base = Config.erp_base_url.chomp('/')
          uri = URI.parse("#{base}/api/resource/#{ERB::Util.url_encode(doctype)}")
          uri.query = URI.encode_www_form(
            fields: FIELDS,
            order_by: ORDER_BY,
            limit_page_length: LIMIT_PAGE_LENGTH
          )
          uri
        end

        def parse_body(raw)
          JSON.parse(raw.presence || '{}')
        rescue JSON::ParserError
          {}
        end
      end
    end
  end
end
