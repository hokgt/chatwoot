# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'erb'

# Isolated options source for the manual Lead Activity form. This is deliberately
# NOT routed through the Lead Details OptionsService / Config::OPTION_DOCTYPES
# flow: Lead Activity names come from their own ERPNext DocType ("Lead Activity
# Master") and are fetched at runtime only when the Activity view opens.
#
# The same runtime list is used to validate both `lead_activity` and a non-empty
# `follow_up_activity` server-side before any insert (see LeadActivityService);
# when the fetch is unavailable the caller must reject before insert.
#
# Declared with the nested module style (matching the sibling battery files) so
# the unqualified `Config` / `SafeHttp` / `SyncError` sibling references resolve.
module Wijaya::Batteries::ErpLeadSidebar
  class LeadActivityOptionsService
    DOCTYPE = 'Lead Activity Master'
    FIELDS = '["name"]'
    ORDER_BY = 'name asc'
    # Frappe treats limit_page_length=0 as "return every record".
    LIMIT_PAGE_LENGTH = 0

    def initialize(account = nil)
      @account = account
    end

    # Sorted list of Lead Activity Master `name`s. Raises SyncError when ERP is
    # unconfigured or the fetch fails, so callers can reject before insert.
    def fetch_names
      raise SyncError, 'ERPNext connection is not configured' unless Config.erp_configured?(@account)

      response = get_list
      body = parse_body(response.body)

      unless response.is_a?(Net::HTTPSuccess)
        message = body['exception'] || body['exc'] || body['message'] || response.message
        raise SyncError, "ERPNext Lead Activity options fetch failed: #{message}"
      end

      Array(body['data']).filter_map { |row| row['name'] if row.is_a?(Hash) }
    end

    # Default form date in the account's reporting timezone (project Time.zone
    # fallback; no custom ENV fallback). Returned to the client so the form opens
    # on "today" for the agent; the field stays editable.
    def default_date
      zone_name = @account&.reporting_timezone.presence
      zone = zone_name && ActiveSupport::TimeZone[zone_name]
      (zone || Time.zone).today.iso8601
    end

    private

    def get_list
      SafeHttp.request(
        method: :get,
        uri: list_uri,
        api_key: Config.erp_api_key(@account),
        api_secret: Config.erp_api_secret(@account)
      )
    end

    def list_uri
      base = Config.erp_base_url(@account).chomp('/')
      uri = URI.parse("#{base}/api/resource/#{ERB::Util.url_encode(DOCTYPE)}")
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
