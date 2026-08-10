# frozen_string_literal: true

require 'date'

# Builds the exact ERPNext `frappe.client.insert` request body for a single
# manual Lead Activity child row, applying strict server-side validation and
# normalization. The browser can never set the structural keys (doctype /
# parenttype / parent / parentfield): those are frozen constants here, and the
# `parent` is supplied by the caller from the server-side draft's erp_lead_id.
#
# Declared with the nested module style (matching the sibling battery files) so
# the unqualified `ValidationError` sibling reference resolves.
module Wijaya::Batteries::ErpLeadSidebar
  class LeadActivityPayloadBuilder
    DOCTYPE = 'Lead Activity'
    PARENTTYPE = 'Lead'
    PARENTFIELD = 'custom_lead_activity'

    FOLLOW_UP_VALUES = %w[No Yes].freeze
    UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    ISO_DATE_REGEX = /\A\d{4}-\d{2}-\d{2}\z/

    # fields:            raw permitted params (indifferent-ish hash)
    # parent:            server-derived ERP Lead name (draft.erp_lead_id)
    # submission_id:     client-generated idempotency UUID
    # valid_activities:  runtime-fetched Lead Activity Master names
    # person_in_charge:  already resolved + verified by the service ('' when none)
    def initialize(fields:, parent:, submission_id:, valid_activities:, person_in_charge:)
      @fields = (fields || {}).transform_keys(&:to_s)
      @parent = parent.to_s
      @submission_id = submission_id.to_s
      @valid_activities = Array(valid_activities).map(&:to_s)
      @person_in_charge = person_in_charge.to_s
    end

    # Returns { 'doc' => { ... } } ready to POST to frappe.client.insert.
    def payload
      validate!

      { 'doc' => document }
    end

    def validate! # rubocop:disable Metrics/CyclomaticComplexity,Metrics/AbcSize
      errors = []
      errors << 'submission_id is invalid' unless @submission_id.match?(UUID_REGEX)
      errors << 'linked ERP Lead is required' if @parent.strip.empty?
      errors << 'date is required' if date.empty?
      errors << 'date must be a valid YYYY-MM-DD' if date.present? && !valid_iso_date?(date)
      errors << 'lead_activity is required' if lead_activity.empty?
      errors << 'lead_activity is not a known Lead Activity' if lead_activity.present? && !@valid_activities.include?(lead_activity)
      errors << 'follow_up must be No or Yes' unless FOLLOW_UP_VALUES.include?(follow_up)

      if follow_up == 'Yes'
        errors << 'follow_up_date must be a valid YYYY-MM-DD' if follow_up_date.present? && !valid_iso_date?(follow_up_date)
        if follow_up_activity.present? && !@valid_activities.include?(follow_up_activity)
          errors << 'follow_up_activity is not a known Lead Activity'
        end
      end

      raise ValidationError, errors.join(', ') if errors.any?
    end

    private

    def document
      {
        'doctype' => DOCTYPE,
        'parenttype' => PARENTTYPE,
        'parent' => @parent,
        'parentfield' => PARENTFIELD,
        'date' => date,
        'lead_activity' => lead_activity,
        'follow_up' => follow_up,
        'follow_up_date' => effective_follow_up_date,
        'follow_up_activity' => effective_follow_up_activity,
        'person_in_charge' => @person_in_charge,
        'remark' => marked_remark
      }
    end

    def date
      normalized(@fields['date'])
    end

    def lead_activity
      normalized(@fields['lead_activity'])
    end

    def follow_up
      normalized(@fields['follow_up'])
    end

    def follow_up_date
      normalized(@fields['follow_up_date'])
    end

    def follow_up_activity
      normalized(@fields['follow_up_activity'])
    end

    # follow_up "No" forces both follow-up fields empty regardless of input.
    def effective_follow_up_date
      follow_up == 'Yes' ? follow_up_date : ''
    end

    def effective_follow_up_activity
      follow_up == 'Yes' ? follow_up_activity : ''
    end

    # Server-owned idempotency marker. Empty remark => marker alone (no trailing
    # space, no leaked content); non-empty => "<marker> <remark>".
    def marked_remark
      marker = "[chatwoot:activity:#{@submission_id}]"
      remark = normalized(@fields['remark'])
      remark.empty? ? marker : "#{marker} #{remark}"
    end

    def normalized(value)
      value.to_s.strip
    end

    def valid_iso_date?(value)
      return false unless value.match?(ISO_DATE_REGEX)

      Date.iso8601(value)
      true
    rescue ArgumentError
      false
    end
  end
end
