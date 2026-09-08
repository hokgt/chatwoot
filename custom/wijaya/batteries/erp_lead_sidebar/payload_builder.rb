# frozen_string_literal: true

module Wijaya::Batteries::ErpLeadSidebar
  class PayloadBuilder
    DIRECT_FIELDS = %w[
      lead_owner first_name company_name whatsapp_no mobile_no status
      utm_source industry territory utm_campaign
    ].freeze

    def initialize(fields)
      @fields = (fields || {}).with_indifferent_access
    end

    def payload
      validate!

      data = { doctype: Config::DOCTYPE }
      DIRECT_FIELDS.each do |field|
        value = normalized_value(@fields[field])
        data[field] = value if value.present?
      end
      # Frozen Phase 1 decision: always send the same phone number to both
      # whatsapp_no and mobile_no. Agent edits are preserved in the draft, but
      # ERP payload keeps mobile_no synchronized with whatsapp_no.
      data['mobile_no'] = data['whatsapp_no'] if data['whatsapp_no'].present?

      checkbox_fields.each do |field|
        data[field] = 1 if truthy?(@fields[field])
      end

      data
    end

    def validate! # rubocop:disable Metrics/CyclomaticComplexity
      errors = []
      status = normalized_value(@fields[:status])
      errors << 'status is required' if status.blank?
      errors << 'status is not allowed' if status.present? && !Config.status_allowed?(status)
      errors << 'industry is required' if normalized_value(@fields[:industry]).blank?

      if normalized_value(@fields[:first_name]).blank? && normalized_value(@fields[:company_name]).blank?
        errors << 'first_name or company_name is required'
      end

      raise ValidationError, errors.join(', ') if errors.any?
    end

    private

    def checkbox_fields
      Config::MARKET_CUSTOMER_FIELDS + Config::JENIS_PAKAIAN_FIELDS
    end

    def normalized_value(value)
      return value unless value.is_a?(String)

      value.strip.empty? ? nil : value
    end

    def truthy?(value)
      value == true || value.to_s == '1'
    end
  end

  class ValidationError < StandardError; end
end
