# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'erb'

module Wijaya
  module Batteries
    module ErpLeadSidebar
      # Freshness refresh for a linked ERP Lead. When a sidebar draft already knows
      # its ERP Lead id, opening the sidebar should reflect the *current* ERP data
      # rather than a stale local snapshot (the lead may have been edited directly
      # in ERPNext). This service fetches the linked Lead and reconciles it with the
      # local draft under a simple conflict policy:
      #
      #   * draft is `synced`      -> overwrite local fields with ERP fields so the
      #                               sidebar shows the current ERP state.
      #   * draft is `draft`/`failed` (unsynced agent edits) -> keep local fields,
      #                               return a conflict message so the UI can warn.
      #   * ERP fetch fails        -> keep local fields, return a soft warning; the
      #                               sidebar must never break because ERP is down.
      #
      # Returns a metadata hash the controller merges into the draft JSON:
      #   { refreshed:, conflict:, message:, remote_fields: }
      # It never returns secrets. When it overwrites, it mutates the draft in place
      # (fields updated, sync_status kept `synced`).
      class RefreshService
        def initialize(draft)
          @draft = draft
        end

        def perform
          return {} unless @draft.erp_lead_id.present? && Config.erp_configured?

          remote = fetch_remote_fields
          return fetch_failed_result if remote.nil?

          if unsynced?
            conflict_result(remote)
          else
            refreshed_result(remote)
          end
        rescue StandardError => e
          Rails.logger.warn("Wijaya ERP Lead refresh failed for #{@draft.erp_lead_id}: #{e.message}") if defined?(Rails)
          fetch_failed_result
        end

        private

        # Draft carries agent edits that have not reached ERP yet.
        def unsynced?
          @draft.sync_status.to_s != 'synced'
        end

        def refreshed_result(remote)
          merged = @draft.fields.merge(remote)
          @draft.update!(fields: merged, sync_status: 'synced', last_error: nil)
          {
            refreshed: true,
            conflict: false,
            message: "Refreshed from ERP Lead #{@draft.erp_lead_id}.",
            remote_fields: remote
          }
        end

        def conflict_result(remote)
          {
            refreshed: false,
            conflict: true,
            message: 'Local unsynced draft kept; ERP has newer/current data. ' \
                     'Click Update Lead to overwrite ERP with your local changes.',
            remote_fields: remote
          }
        end

        def fetch_failed_result
          {
            refreshed: false,
            conflict: false,
            message: "Could not refresh from ERP Lead #{@draft.erp_lead_id}; showing local draft."
          }
        end

        # GET the linked Lead and map it to sidebar draft fields, or nil on any
        # transport/HTTP error so the caller can fall back to local data.
        def fetch_remote_fields
          response = request_get(resource_uri(@draft.erp_lead_id))
          return nil unless response.is_a?(Net::HTTPSuccess)

          data = parse_body(response.body)['data']
          return nil unless data.is_a?(Hash)

          map_fields(data)
        end

        # ERP doc -> draft fields. Direct fields pass through as returned (nil ->
        # ''); checkbox groups are coerced to booleans so the UI reflects ERP for
        # every known key.
        def map_fields(data)
          mapped = {}
          PayloadBuilder::DIRECT_FIELDS.each do |field|
            mapped[field] = data[field].nil? ? '' : data[field]
          end
          checkbox_fields.each do |field|
            mapped[field] = truthy?(data[field])
          end
          mapped
        end

        def checkbox_fields
          Config::MARKET_CUSTOMER_FIELDS + Config::JENIS_PAKAIAN_FIELDS
        end

        def truthy?(value)
          value == true || value == 1 || value.to_s == '1'
        end

        def request_get(uri)
          request = Net::HTTP::Get.new(uri)
          request['Authorization'] = "token #{Config.erp_api_key}:#{Config.erp_api_secret}"

          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
            http.request(request)
          end
        end

        def resource_uri(name)
          base = "#{Config.erp_base_url.chomp('/')}/api/resource/Lead/#{ERB::Util.url_encode(name)}"
          URI.parse(base)
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
