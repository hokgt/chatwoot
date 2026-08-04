# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'erb'

module Wijaya::Batteries::ErpLeadSidebar
  class SyncService
    # ERP columns probed when matching an existing Lead by phone number.
    PHONE_LOOKUP_FIELDS = %w[whatsapp_no mobile_no].freeze

    def initialize(draft)
      @draft = draft
    end

    # Idempotent ERP Lead sync. A given draft maps to at most one ERP Lead:
    #   * If the draft already knows its ERP Lead id, we PUT-update that Lead.
    #   * Otherwise we first look for an existing Lead with the same phone
    #     number and adopt it (PUT-update) instead of creating a duplicate.
    #   * Only when nothing is found do we POST-create a new Lead.
    def perform
      raise SyncError, 'ERPNext connection is not configured' unless Config.erp_configured?

      payload = PayloadBuilder.new(@draft.fields).payload

      lead_name =
        if @draft.erp_lead_id.present?
          sync_existing(@draft.erp_lead_id, payload)
        else
          matched = find_existing_lead_by_phone(payload)
          matched.present? ? sync_existing(matched, payload) : create_new(payload)
        end

      @draft.update!(erp_lead_id: lead_name, sync_status: 'synced', last_error: nil, last_payload: payload)
      { erp_lead_id: lead_name, payload: payload }
    end

    private

    # PUT-updates an existing ERP Lead. A 404 here means the stored id no
    # longer exists in ERP; we must NOT silently create a duplicate, so we
    # raise and ask for a relink instead.
    def sync_existing(name, payload)
      response = request_json(Net::HTTP::Put, resource_uri(name), payload)
      body = parse_body(response.body)

      raise SyncError, "Stored ERP Lead '#{name}' was not found in ERPNext; relink required." if response.is_a?(Net::HTTPNotFound)

      raise SyncError, "ERPNext sync failed: #{error_message(body, response)}" unless response.is_a?(Net::HTTPSuccess)

      extract_lead_name(body).presence || name
    end

    def create_new(payload)
      response = request_json(Net::HTTP::Post, resource_uri, payload)
      body = parse_body(response.body)

      raise SyncError, "ERPNext sync failed: #{error_message(body, response)}" unless response.is_a?(Net::HTTPSuccess)

      lead_name = extract_lead_name(body)
      raise SyncError, 'ERPNext response did not include Lead name' if lead_name.blank?

      lead_name
    end

    # Looks for an existing ERP Lead sharing this draft's phone number so a
    # post-create edit does not spawn a duplicate. Frappe OR-filters are
    # awkward over REST, so we probe each phone value against both the
    # whatsapp_no and mobile_no columns and take the first hit.
    def find_existing_lead_by_phone(payload)
      phones = [payload['whatsapp_no'], payload['mobile_no']].map { |value| value.to_s.strip }.reject(&:empty?).uniq
      phones.each do |phone|
        PHONE_LOOKUP_FIELDS.each do |field|
          name = lookup_lead(field, phone)
          return name if name.present?
        end
      end
      nil
    end

    def lookup_lead(field, phone)
      response = request_json(Net::HTTP::Get, list_uri(field, phone), nil)
      return nil unless response.is_a?(Net::HTTPSuccess)

      body = parse_body(response.body)
      row = Array(body['data']).find { |item| item.is_a?(Hash) && item['name'].present? }
      row && row['name']
    end

    def request_json(request_class, uri, payload)
      request = request_class.new(uri)
      request['Authorization'] = "token #{Config.erp_api_key}:#{Config.erp_api_secret}"
      if payload
        request['Content-Type'] = 'application/json'
        request.body = payload.to_json
      end

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(request)
      end
    end

    # /api/resource/Lead for create/list, /api/resource/Lead/:name for update.
    def resource_uri(name = nil)
      base = "#{Config.erp_base_url.chomp('/')}/api/resource/Lead"
      base += "/#{ERB::Util.url_encode(name)}" if name.present?
      URI.parse(base)
    end

    def list_uri(field, phone)
      uri = resource_uri
      uri.query = URI.encode_www_form(
        fields: '["name","whatsapp_no","mobile_no"]',
        filters: [['Lead', field, '=', phone]].to_json,
        limit_page_length: 1
      )
      uri
    end

    def parse_body(raw)
      JSON.parse(raw.presence || '{}')
    rescue JSON::ParserError
      {}
    end

    def error_message(body, response)
      return response.message unless body.is_a?(Hash)

      body['exception'].presence || body['exc'].presence || body['message'].presence || response.message
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
