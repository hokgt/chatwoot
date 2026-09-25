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
    MALFORMED_MESSAGE = 'ERPNext Lead Activity options response was malformed'

    def initialize(account = nil)
      @account = account
    end

    # Sorted list of Lead Activity Master `name`s, tolerating a malformed 2xx body
    # as an empty list. Raises SyncError when ERP is unconfigured or the fetch
    # fails. Kept for the POST insert-validation path (LeadActivityService): its
    # contract is unchanged — any malformed successful body (a non-array `data`, a
    # non-hash row, or a row without a usable name) still collapses to [] here.
    def fetch_names
      names_from(fetch_data)
    end

    # Strict variant for the read-only options endpoint: a malformed successful
    # body is raised as MalformedResponseError rather than silently collapsing to a
    # valid-empty list. Malformed covers a non-array `data`, a non-hash row, and a
    # row with a missing/blank name. A genuinely empty `data` array is still
    # returned as [] (a valid empty list).
    def fetch_activity_names
      strict_names_from(fetch_data)
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

    # Performs the credentialed list request and returns the raw `data` value from a
    # 2xx body (which may be malformed — each caller classifies it). Raises SyncError
    # when unconfigured or on a non-2xx response.
    def fetch_data
      raise SyncError, 'ERPNext connection is not configured' unless Config.erp_configured?(@account)

      response = request_list
      raise UpstreamHttpError, response.code.to_i unless response.is_a?(Net::HTTPSuccess)

      parse_body(response.body)['data']
    end

    # Tolerant projection for the POST path: skip anything that is not a hash row
    # carrying a name, so any malformed shape degrades to [] instead of raising.
    def names_from(data)
      Array(data).filter_map { |row| row['name'] if row.is_a?(Hash) }
    end

    # Strict projection for the read path: the whole shape must be well-formed —
    # `data` an array of hashes, each with a nonblank `name`. Any deviation is a
    # MalformedResponseError; a genuinely empty array stays a valid empty list.
    def strict_names_from(data)
      raise MalformedResponseError, MALFORMED_MESSAGE unless data.is_a?(Array)

      data.map do |row|
        name = row['name'] if row.is_a?(Hash)
        raise MalformedResponseError, MALFORMED_MESSAGE if name.to_s.strip.empty?

        name
      end
    end

    def request_list
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

    # Always yields a Hash: a non-object top-level body (e.g. a bare JSON array) is
    # coerced to {} so callers never index a non-hash, and the strict path then sees
    # a missing `data` (malformed) while the tolerant path sees [].
    def parse_body(raw)
      parsed = JSON.parse(raw.presence || '{}')
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
