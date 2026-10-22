# frozen_string_literal: true

module Wijaya::Batteries::ErpLeadSidebar
  class PayloadBuilder
    # lead_owner is intentionally NOT here: the sidebar full Lead create/update never emits an
    # owner. The ERP Lead owner has its own dedicated, validated path — the erp_lead_owner_sync
    # battery's owner-ONLY OwnerSyncJob/OwnerSyncService, run AFTER the Lead is linked. It syncs
    # either the committed assignee email (automatic default) or the agent's sticky manual owner
    # chosen from the live ERP User directory, and only after that value is revalidated as a real
    # enabled non-Guest ERP User. Keeping owner out of this generic list guarantees no unvalidated
    # browser value rides the full-field payload; the owner reaches ERP solely through that
    # dedicated path, even if a stale draft still carries fields['lead_owner'].
    # product_requirements (Text, multiline) rides the normal Lead payload as a plain
    # string. product_requirement is an ERP Table MultiSelect (NOT a single Link): the
    # draft holds an ordered array of unique ERP "Lead Product Requirements" document
    # names, and the Lead payload sends it as an array of child rows
    # ([{ product_requirement: name }, ...]) — see #payload / .requirement_rows. Both
    # stay in DIRECT_FIELDS so the controller allowlist and refresh field set include
    # them, but product_requirement is built/mapped explicitly (skipped in the generic
    # scalar loops). product_name/product_price are DELIBERATELY absent: they belong
    # only to the Product Requirements create path and must never enter the Lead payload.
    DIRECT_FIELDS = %w[
      first_name company_name whatsapp_no mobile_no status
      utm_source industry territory utm_campaign
      product_requirements product_requirement
    ].freeze

    # The Table MultiSelect field handled explicitly (not through the scalar loops).
    MULTISELECT_FIELD = 'product_requirement'

    # Normalize any accepted product_requirement shape into the canonical ordered array
    # of unique ERP master document names: a legacy scalar string, nil/blank, an array
    # of names, or an array of ERP child rows ({ 'product_requirement' => name }). Blanks
    # and duplicates are dropped (order preserved) and malformed entries are ignored — a
    # browser can never smuggle extra child-row keys through, and only a String name is
    # ever read, so a nested hash/other type fails closed instead of being forwarded.
    def self.requirement_names(value)
      Array.wrap(value).filter_map { |row| requirement_name(row) }.uniq
    end

    def self.requirement_name(row)
      raw =
        case row
        when String then row
        when Hash then row.with_indifferent_access[MULTISELECT_FIELD]
        end
      return nil unless raw.is_a?(String)

      name = raw.strip
      name.empty? ? nil : name
    end

    # Canonical ERP Table MultiSelect child rows for the Lead payload.
    def self.requirement_rows(value)
      requirement_names(value).map { |name| { MULTISELECT_FIELD => name } }
    end

    def initialize(fields)
      @fields = (fields || {}).with_indifferent_access
    end

    def payload
      validate!

      data = { doctype: Config::DOCTYPE }
      assign_scalar_fields(data)
      assign_requirement_rows(data)
      # Frozen Phase 1 decision: always send the same phone number to both
      # whatsapp_no and mobile_no. Agent edits are preserved in the draft, but
      # ERP payload keeps mobile_no synchronized with whatsapp_no.
      data['mobile_no'] = data['whatsapp_no'] if data['whatsapp_no'].present?
      assign_checkbox_fields(data)

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

    # Scalar direct fields ride the payload as trimmed strings. product_requirement is
    # skipped here — it is a Table MultiSelect built as child rows below.
    def assign_scalar_fields(data)
      DIRECT_FIELDS.each do |field|
        next if field == MULTISELECT_FIELD

        value = normalized_value(@fields[field])
        data[field] = value if value.present?
      end
    end

    # product_requirement as ERP Table MultiSelect child rows. Presence of the KEY, not
    # of any value, decides whether the field rides the payload: whenever the draft/input
    # carries product_requirement it is always sent — as [] when the normalized selection
    # is empty — so removing the final chip on a linked Lead clears the ERP child rows on
    # update. Only a truly absent key (legacy/server-created draft) is omitted, so an
    # unrelated field update never unexpectedly wipes existing ERP data.
    def assign_requirement_rows(data)
      return unless @fields.key?(MULTISELECT_FIELD)

      data[MULTISELECT_FIELD] = self.class.requirement_rows(@fields[MULTISELECT_FIELD])
    end

    def assign_checkbox_fields(data)
      checkbox_fields.each do |field|
        data[field] = 1 if truthy?(@fields[field])
      end
    end

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
