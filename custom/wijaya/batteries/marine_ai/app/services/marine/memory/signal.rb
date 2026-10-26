# frozen_string_literal: true

# Closed, fact-free completion signal persisted on the exact incoming trigger Message.
# Trust requires an exact payload and a completed ProcessingClaim on that same carrier.
# rubocop:disable Metrics/ModuleLength -- Closed signal construction and trust contract is intentionally colocated.
module Marine::Memory::Signal
  KEY = 'marine_memory_signal_v1'
  VERSION = 'marine_memory_signal_v1'
  KEYS = %w[schema_version status requested_capabilities delivered_capabilities
            evidence_versions public_reply_message_id].freeze
  STATUSES = %w[complete blocking neutral].freeze
  CAPABILITIES = %w[price price_range stock product_listing product_information
                    company_offerings catalog_attachment].freeze
  EVIDENCE_VERSIONS = %w[marine_evidence_v2 marine_evidence_v3].freeze
  MAX_CAPABILITIES = CAPABILITIES.length
  MAX_EVIDENCE_VERSIONS = 4

  module_function

  def build(status:, requested_capabilities:, delivered_capabilities:, evidence_versions:,
            public_reply_message_id: nil)
    payload = {
      'schema_version' => VERSION,
      'status' => status.to_s,
      'requested_capabilities' => normalize_array(requested_capabilities),
      'delivered_capabilities' => normalize_array(delivered_capabilities),
      'evidence_versions' => normalize_array(evidence_versions),
      'public_reply_message_id' => public_reply_message_id
    }
    raise ArgumentError, 'invalid marine memory signal' unless valid_shape?(payload)

    payload.freeze
  end

  def write!(message:, **attributes)
    payload = build(**attributes)
    raise ArgumentError, 'signal carrier must have a completed processing claim' unless completed_claim?(message)

    additional = message.additional_attributes.to_h.deep_dup
    additional[KEY] = payload
    message.update!(additional_attributes: additional)
    payload
  end

  def extract(message)
    payload = message.additional_attributes.to_h[KEY]
    return nil unless valid_shape?(payload) && trusted_carrier?(message) && completed_claim?(message)
    return nil unless trusted_reply?(message, payload['public_reply_message_id'])

    payload
  rescue StandardError
    nil
  end

  # rubocop:disable Metrics/CyclomaticComplexity -- Exact signal shape checks stay explicit.
  def valid_shape?(payload)
    payload.is_a?(Hash) && exact_keys?(payload) && payload['schema_version'] == VERSION &&
      STATUSES.include?(payload['status']) && valid_capabilities?(payload) &&
      valid_evidence_versions?(payload['evidence_versions']) && valid_reply_id?(payload['public_reply_message_id']) &&
      valid_status_semantics?(payload)
  end

  # rubocop:enable Metrics/CyclomaticComplexity

  def normalize_array(values)
    Array(values).map(&:to_s).freeze
  end
  private_class_method :normalize_array

  def exact_keys?(payload)
    payload.keys.map(&:to_s).sort == KEYS.sort
  end
  private_class_method :exact_keys?

  def valid_capabilities?(payload)
    requested = payload['requested_capabilities']
    delivered = payload['delivered_capabilities']
    valid_closed_array?(requested, CAPABILITIES, MAX_CAPABILITIES) &&
      valid_closed_array?(delivered, CAPABILITIES, MAX_CAPABILITIES) &&
      (delivered - requested).empty?
  end
  private_class_method :valid_capabilities?

  def valid_evidence_versions?(versions)
    valid_closed_array?(versions, EVIDENCE_VERSIONS, MAX_EVIDENCE_VERSIONS)
  end
  private_class_method :valid_evidence_versions?

  def valid_closed_array?(values, allowlist, maximum)
    values.is_a?(Array) && values.length <= maximum && values.uniq == values &&
      values.all? { |value| value.is_a?(String) && allowlist.include?(value) }
  end
  private_class_method :valid_closed_array?

  def valid_reply_id?(value)
    value.nil? || (value.is_a?(Integer) && value.positive?)
  end
  private_class_method :valid_reply_id?

  # rubocop:disable Metrics/CyclomaticComplexity -- Closed status semantics are a truth table.
  def valid_status_semantics?(payload)
    requested = payload['requested_capabilities']
    delivered = payload['delivered_capabilities']
    case payload['status']
    when 'complete' then requested.any? && delivered == requested && payload['public_reply_message_id'].present?
    when 'neutral' then requested.empty? && delivered.empty? && payload['evidence_versions'].empty?
    when 'blocking' then delivered.length <= requested.length
    else false
    end
  end
  private_class_method :valid_status_semantics?
  # rubocop:enable Metrics/CyclomaticComplexity

  def trusted_carrier?(message)
    return false unless message.is_a?(::Message) && message.incoming? && !message.private?

    conversation = message.conversation
    conversation.present? && message.conversation_id == conversation.id &&
      message.account_id == conversation.account_id && message.inbox_id == conversation.inbox_id
  end
  private_class_method :trusted_carrier?

  def completed_claim?(message)
    claim = Marine::Conversation::ProcessingClaim.new(message: message).current
    claim.is_a?(Hash) && claim['status'] == Marine::Conversation::ProcessingClaim::LIFECYCLE_COMPLETED &&
      claim['message_id'] == message.id
  end
  private_class_method :completed_claim?

  def trusted_reply?(message, reply_id)
    return true if reply_id.nil?

    assistant_id = MarineInbox.find_by(inbox_id: message.inbox_id)&.marine_assistant_id
    return false unless assistant_id

    message.conversation.messages.outgoing.where(
      id: reply_id, private: false, account_id: message.account_id, inbox_id: message.inbox_id,
      sender_type: 'Marine::Assistant', sender_id: assistant_id
    ).exists?(['messages.id > ? AND messages.created_at >= ?', message.id, message.created_at])
  end
  private_class_method :trusted_reply?
end
# rubocop:enable Metrics/ModuleLength
