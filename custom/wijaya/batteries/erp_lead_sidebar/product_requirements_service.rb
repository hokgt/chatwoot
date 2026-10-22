# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'erb'

# Backend for the ERP Lead "Product Requirement" Link field. Reads and creates
# records in the EXISTING ERPNext DocType "Lead Product Requirements" (never
# altering its schema). Deliberately kept separate from the Lead Details
# OptionsService/Config::OPTION_DOCTYPES flow: those dropdowns are small,
# fully-loaded selects; this one is a searchable, bounded, on-demand master-data
# picker with its own create path, so folding it into OptionsService would turn
# that simple loader into an unbounded master-data service.
#
# Contract:
#   * #list returns bounded [{ value:, label: }] rows — value is the ERP
#     document `name` (what is stored/sent), label is `product_name` (what is
#     shown). A blank/short query lists the first page; a nonblank query filters
#     by product_name (case-insensitive, whitespace-collapsed) server-side.
#   * #create validates locally, then prevents duplicates with a server-side
#     exact normalized lookup (trim, case-insensitive, collapse repeated
#     whitespace) BEFORE any POST: a match returns the existing record with
#     duplicate: true and issues zero create call. Otherwise it POSTs
#     product_name + raw numeric product_price only.
#   * product_name/product_price are the ONLY fields ever written; the browser
#     can never inject other DocType fields here.
#
# Declared with the nested module style (matching the sibling battery files) so
# the unqualified `Config` / `SafeHttp` / `SyncError` / `ValidationError`
# sibling references resolve.
# rubocop:disable Style/ClassAndModuleChildren -- nested style preserves sibling constant resolution
module Wijaya::Batteries::ErpLeadSidebar
  class ProductRequirementsService
    # Frozen EXISTING ERPNext DocType. Never created or modified here.
    DOCTYPE = 'Lead Product Requirements'
    LIST_FIELDS = '["name","product_name"]'
    ORDER_BY = 'product_name asc'
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 50
    # A generous product name bound; only rejects an oversized manipulated value
    # before it can reach ERP, never an ordinary name.
    MAX_NAME_LENGTH = 255
    # Bounded candidate scan for the pre-create duplicate lookup.
    DUP_SCAN_LIMIT = 50

    def initialize(account = nil)
      @account = account
    end

    # Bounded, searchable list of [{ value:, label: }]. value = ERP `name`
    # (stored/sent), label = `product_name` (displayed). Raises SyncError when
    # unconfigured or the fetch fails/returns a malformed shape.
    def list(query: nil, limit: nil)
      raise SyncError, 'ERPNext connection is not configured' unless Config.erp_configured?(@account)

      body = get_json(list_uri(search: query, limit: bounded_limit(limit)))
      rows_to_options(body['data'])
    end

    # Local-validate, then dedupe server-side, then create. Returns
    # { value:, label:, duplicate: } — duplicate: true means an existing record
    # matched (zero POST). Raises ValidationError on invalid input (before any
    # network call) and SyncError on ERP failure.
    def create(product_name:, product_price:)
      raise SyncError, 'ERPNext connection is not configured' unless Config.erp_configured?(@account)

      name = normalized_name(product_name)
      price = validated_price(product_price)

      existing = find_existing(name)
      return existing.merge(duplicate: true) if existing

      insert(name, price).merge(duplicate: false)
    end

    private

    # --- validation -----------------------------------------------------------

    # Trim + collapse repeated whitespace. Raises on blank/oversized input BEFORE
    # any network call so a bad value never reaches ERP.
    def normalized_name(value)
      name = value.to_s.strip.gsub(/\s+/, ' ')
      raise ValidationError, 'Product Name is required' if name.empty?
      raise ValidationError, 'Product Name is too long' if name.length > MAX_NAME_LENGTH

      name
    end

    # Raw whole-number price. Blank is permitted (omitted from the payload). Any
    # nonblank value must be a non-negative integer with no formatting — a
    # grouped string like "50.000", a negative, or a decimal is rejected here,
    # BEFORE any network call. Returns an Integer or nil.
    def validated_price(value)
      raw = value.to_s.strip
      return nil if raw.empty?
      raise ValidationError, 'Product Price must be a whole number of 0 or more' unless raw.match?(/\A\d+\z/)

      raw.to_i
    end

    # --- duplicate lookup -----------------------------------------------------

    # Server-side exact normalized match. A LIKE pattern with internal whitespace
    # runs replaced by `%` finds case-insensitive, whitespace-collapsed candidates
    # at the DB; each candidate is then re-verified with an exact normalized
    # comparison in Ruby (so `blue%shirt` can never falsely match "blueXshirt").
    # Never trusts any browser-supplied option list.
    def find_existing(name)
      body = get_json(list_uri(filters: [[DOCTYPE, 'product_name', 'like', like_pattern(name)]], limit: DUP_SCAN_LIMIT))
      key = comparison_key(name)
      Array(body['data']).each do |row|
        next unless row.is_a?(Hash)

        return option_for(row) if comparison_key(row['product_name']) == key
      end
      nil
    end

    def comparison_key(value)
      value.to_s.strip.gsub(/\s+/, ' ').downcase
    end

    # Case-insensitive, whitespace-collapsed LIKE pattern: escape LIKE
    # metacharacters in each token, then join tokens with `%` so any run of
    # whitespace matches. No surrounding `%`, so it anchors to the whole value.
    def like_pattern(name)
      name.split(/\s+/).map { |token| escape_like(token) }.join('%')
    end

    def escape_like(token)
      token.gsub(/[\\%_]/) { |char| "\\#{char}" }
    end

    # --- create ---------------------------------------------------------------

    def insert(name, price)
      payload = { doctype: DOCTYPE, product_name: name }
      payload[:product_price] = price unless price.nil?

      response = SafeHttp.request(
        method: :post,
        uri: resource_uri,
        api_key: Config.erp_api_key(@account),
        api_secret: Config.erp_api_secret(@account),
        body: payload.to_json
      )
      raise UpstreamHttpError, response.code.to_i unless response.is_a?(Net::HTTPSuccess)

      created = parse_object(response.body)['data']
      raise MalformedResponseError, 'ERPNext create response was malformed' unless created.is_a?(Hash)

      option = option_for(created)
      raise MalformedResponseError, 'ERPNext create response was malformed' unless option

      option
    end

    # --- shared HTTP ----------------------------------------------------------

    def get_json(uri)
      response = SafeHttp.request(
        method: :get,
        uri: uri,
        api_key: Config.erp_api_key(@account),
        api_secret: Config.erp_api_secret(@account)
      )
      raise UpstreamHttpError, response.code.to_i unless response.is_a?(Net::HTTPSuccess)

      parse_object(response.body)
    end

    # value = ERP name (stored/sent), label = product_name (shown). The list must
    # display ONLY product_name, so a row is unusable — nil — when either the ERP
    # `name` or `product_name` is blank; the ERP document id is never surfaced as a
    # label. nil rows are skipped in the list and treated as malformed on create.
    def option_for(row)
      return nil unless row.is_a?(Hash)

      value = row['name'].to_s
      label = row['product_name'].to_s.strip
      return nil if value.empty? || label.empty?

      { value: value, label: label }
    end

    def rows_to_options(data)
      raise MalformedResponseError, 'ERPNext Product Requirements response was malformed' unless data.is_a?(Array)

      data.filter_map { |row| option_for(row) }
    end

    def bounded_limit(limit)
      value = limit.to_i
      return DEFAULT_LIMIT if value <= 0

      [value, MAX_LIMIT].min
    end

    def resource_uri
      URI.parse("#{Config.erp_base_url(@account).chomp('/')}/api/resource/#{ERB::Util.url_encode(DOCTYPE)}")
    end

    def list_uri(search: nil, filters: nil, limit: DEFAULT_LIMIT)
      uri = resource_uri
      query = { fields: LIST_FIELDS, order_by: ORDER_BY, limit_page_length: limit }
      effective_filters = filters || search_filters(search)
      query[:filters] = effective_filters.to_json if effective_filters
      uri.query = URI.encode_www_form(query)
      uri
    end

    # A nonblank query filters product_name with a case-insensitive, whitespace-
    # collapsed contains match; a blank query lists the first bounded page.
    def search_filters(search)
      term = search.to_s.strip.gsub(/\s+/, ' ')
      return nil if term.empty?

      [[DOCTYPE, 'product_name', 'like', "%#{like_pattern(term)}%"]]
    end

    def parse_object(raw)
      parsed = JSON.parse(raw.presence || '{}')
      raise MalformedResponseError, 'ERPNext Product Requirements returned an unexpected response' unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise MalformedResponseError, 'ERPNext Product Requirements returned an unparseable response'
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
