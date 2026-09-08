# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'erb'

# Reads select-option values from ERPNext for the Lead sidebar dropdowns.
#
# Each dropdown (Source, Campaign, Territory, Industry) is populated from the
# `name` of documents in a specific ERPNext DocType (see Config::OPTION_DOCTYPES).
# Frappe exposes these via GET /api/resource/:doctype. Auth reuses the same
# server-side token as SyncService so the API secret never reaches the browser.
# Declared under `module Wijaya::Batteries::ErpLeadSidebar` (matching the sibling
# battery files) so ErpLeadSidebar stays in Module.nesting and the unqualified
# `Config`/`SyncError` sibling references below resolve. A fully compacted
# `class Wijaya::Batteries::ErpLeadSidebar::OptionsService` leaves only the leaf in
# the nesting, so those references raise NameError at call time.
module Wijaya::Batteries::ErpLeadSidebar
  class OptionsService
    FIELDS = '["name"]'
    ORDER_BY = 'name asc'
    # Frappe treats limit_page_length=0 as "return every record".
    LIMIT_PAGE_LENGTH = 0

    # ERPNext's "UTM Source" DocType mixes true ad/campaign sources
    # (e.g. "Ads Februari 26", "Ads November 25", "Meta Ads April 2026") with
    # non-ad channels such as "Cold Calling", "Campaign" and "China Homelife".
    # Pak Ahok requires ERP Lead > Source to only offer ad/campaign-style
    # values, and the UTM Source records carry no category/disabled flag to
    # key off, so we allowlist by name. Matching is word/token based on
    # purpose to avoid false positives:
    #   * /\bads?\b/i keeps "Ads ..."/"Meta Ads ..." but does NOT fire on
    #     "COLD LEADS" ("ads" there is inside "leads", no word boundary).
    #   * /\bmeta\b/i, /iklan/i, /advertisement/i cover the other ad spellings.
    # "Campaign" and "China Homelife" contain none of these tokens and drop out.
    AD_SOURCE_PATTERNS = [
      /\bads?\b/i,
      /\bmeta\b/i,
      /iklan/i,
      /advertisement/i
    ].freeze

    # Smoke-friendly predicate: true when an ERP UTM Source name looks like an
    # ad/campaign source and should stay in the Source dropdown.
    def self.ad_source?(name)
      AD_SOURCE_PATTERNS.any? { |pattern| pattern.match?(name.to_s) }
    end

    # Resolves ERP credentials for the given account (DB settings, then ENV
    # fallback). Passing no account resolves ENV only (legacy behavior).
    def initialize(account = nil)
      @account = account
    end

    # Returns { 'utm_source' => [...], 'utm_campaign' => [...], ... } keyed by
    # the Chatwoot draft field, with each value a sorted list of ERP names.
    # The `utm_source` list is narrowed to ad/campaign sources (see
    # AD_SOURCE_PATTERNS); the other dropdowns pass through unfiltered.
    def fetch_all
      raise SyncError, 'ERPNext connection is not configured' unless Config.erp_configured?(@account)

      Config::OPTION_DOCTYPES.to_h do |field, doctype|
        names = fetch_names(doctype)
        names = names.select { |name| self.class.ad_source?(name) } if field == 'utm_source'
        [field, names]
      rescue SyncError => e
        Rails.logger.warn("Wijaya ERP Lead options fetch skipped for #{doctype}: #{e.class}") if defined?(Rails)
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
      SafeHttp.request(
        method: :get,
        uri: uri,
        api_key: Config.erp_api_key(@account),
        api_secret: Config.erp_api_secret(@account)
      )
    end

    def list_uri(doctype)
      base = Config.erp_base_url(@account).chomp('/')
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
