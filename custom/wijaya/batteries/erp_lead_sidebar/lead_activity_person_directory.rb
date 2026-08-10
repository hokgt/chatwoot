# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

# Account-scoped ERPNext User directory for the manual Lead Activity
# "person in charge" field. The agent picks the person in charge themselves;
# this module is the ONLY source of the selectable choices and the single
# server-side gatekeeper that re-confirms a chosen value before it is recorded.
#
# Why this exists: person_in_charge is a Link -> User field. The browser is
# untrusted, so (1) the choices are fetched here from ERPNext (only enabled,
# non-Guest Users, exposing just value + label), and (2) any nonblank value the
# browser submits is exact-revalidated here immediately before insert. A value
# that is not an exact, currently-selectable User never reaches ERP.
#
# Availability is distinguished from validity: a definite "no such user" answer
# returns false (=> the service rejects with 422), while a transport / non-2xx /
# unparseable failure raises SyncError (=> the service returns 502). Raw ERP
# bodies, exceptions, and credentials never leave this module.
#
# Declared with the nested module style (matching the sibling battery files) so
# the unqualified `Config` / `SafeHttp` / `SyncError` sibling references resolve.
module Wijaya::Batteries::ErpLeadSidebar
  module LeadActivityPersonDirectory
    DOCTYPE = 'User'
    GUEST = 'Guest'
    LIST_FIELDS = '["name","full_name"]'
    EXACT_FIELDS = '["name"]'
    ORDER_BY = 'full_name asc'
    # Frappe treats limit_page_length=0 as "return every record".
    LIMIT_ALL = 0
    # A real ERPNext User.name (an email/login) is far shorter than this. The
    # bound only rejects an oversized manipulated browser value as a definite
    # invalid before it can reach the User directory; it never rejects an
    # ordinary name.
    MAX_NAME_LENGTH = 255

    module_function

    # Sanitized, deterministically sorted [{ value:, label: }] for every
    # selectable ERP User (enabled=1, name != Guest). value is the exact
    # User.name (the Link value); label is full_name, falling back to name.
    # Raises SyncError when the directory is unavailable so the caller can
    # degrade to an empty, optional list.
    def fetch_options(account)
      body = get_json(account, list_uri(account))
      Array(body['data'])
        .filter_map { |row| option_for(row) }
        .sort_by { |option| [option[:label].downcase, option[:value]] }
    end

    # True only when `name` is an exact, currently-selectable ERP User
    # (enabled=1, name != Guest). A blank name is never valid here (the caller
    # treats blank as the permitted "no person in charge"); an oversized value
    # (> MAX_NAME_LENGTH) is a definite invalid and never touches the directory.
    # Raises SyncError when
    # the directory is unavailable, which is deliberately distinct from a
    # definite "no such user" (=> false).
    def valid?(account, name)
      target = name.to_s
      return false if target.empty?
      return false if target.length > MAX_NAME_LENGTH

      body = get_json(account, exact_uri(account, target))
      Array(body['data']).any? { |row| row.is_a?(Hash) && row['name'] == target }
    end

    # --- internals ------------------------------------------------------------

    def option_for(row)
      return nil unless row.is_a?(Hash)

      value = row['name'].to_s
      return nil if value.empty?

      { value: value, label: row['full_name'].to_s.presence || value }
    end

    # Performs the credentialed GET and returns the parsed JSON object. Raises
    # SyncError on any non-success response or unparseable body so the caller
    # never mistakes an ERP outage for a definite "no such user". Transport
    # failures already arrive as SyncError from SafeHttp.
    def get_json(account, uri)
      response = SafeHttp.request(
        method: :get,
        uri: uri,
        api_key: Config.erp_api_key(account),
        api_secret: Config.erp_api_secret(account)
      )
      raise SyncError, 'ERPNext User directory fetch failed' unless response.is_a?(Net::HTTPSuccess)

      parse_object(response.body)
    end

    def parse_object(raw)
      parsed = JSON.parse(raw.presence || '{}')
      raise SyncError, 'ERPNext User directory returned an unexpected response' unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise SyncError, 'ERPNext User directory returned an unparseable response'
    end

    def list_uri(account)
      uri = base_user_uri(account)
      uri.query = URI.encode_www_form(
        fields: LIST_FIELDS,
        filters: enabled_non_guest_filters,
        order_by: ORDER_BY,
        limit_page_length: LIMIT_ALL
      )
      uri
    end

    def exact_uri(account, name)
      uri = base_user_uri(account)
      uri.query = URI.encode_www_form(
        fields: EXACT_FIELDS,
        filters: enabled_non_guest_filters([['User', 'name', '=', name]]),
        limit_page_length: 1
      )
      uri
    end

    # Strict server-side allowlist: only enabled, non-Guest Users are ever
    # queried; callers may append one extra exact-name filter.
    def enabled_non_guest_filters(extra = [])
      ([['User', 'enabled', '=', 1], ['User', 'name', '!=', GUEST]] + extra).to_json
    end

    def base_user_uri(account)
      URI.parse("#{Config.erp_base_url(account).chomp('/')}/api/resource/#{DOCTYPE}")
    end
  end
end
