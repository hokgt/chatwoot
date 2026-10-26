# frozen_string_literal: true

# Closed provenance contracts for Marine-authored long-term-memory private notes.
# Existing v1 notes remain trusted; every new note uses the stricter v2 contract.
# rubocop:disable Metrics/ModuleLength -- Closed v1/v2 provenance contract is intentionally colocated.
module Marine::Memory::Marker
  KEY = 'wijaya_marine_memory'
  KIND = 'marine_long_term_memory'
  FINGERPRINT = /\A[0-9a-f]{64}\z/

  VERSION = 1
  GENERATOR = 'marine_llm_v1'
  STATES = %w[checkpoint final].freeze
  KEYS = %w[version kind state source_account_id source_contact_id source_conversation_id
            start_public_message_id end_public_message_id transcript_fingerprint generator].freeze

  VERSION_V2 = 2
  GENERATOR_V2 = 'marine_llm_v2'
  TRIGGER_SOURCES = %w[idle_timeout cron_fallback].freeze
  MEMORY_SIGNAL_VERSION = 'marine_memory_signal_v1'
  V2_KEYS = %w[version kind source_account_id source_contact_id source_conversation_id
               start_public_message_id end_public_message_id transcript_fingerprint generator
               trigger_source memory_signal_version].freeze

  module_function

  # Retained only for existing v1 fixtures and compatibility. New writes use #build_v2.
  def build(state:, conversation:, start_id:, end_id:, fingerprint:)
    common(conversation, start_id, end_id, fingerprint).merge(
      'version' => VERSION, 'state' => state, 'generator' => GENERATOR
    )
  end

  def build_v2(trigger_source:, conversation:, start_id:, end_id:, fingerprint:)
    common(conversation, start_id, end_id, fingerprint).merge(
      'version' => VERSION_V2,
      'generator' => GENERATOR_V2,
      'trigger_source' => trigger_source,
      'memory_signal_version' => MEMORY_SIGNAL_VERSION
    )
  end

  def extract(message)
    marker = message.additional_attributes.to_h[KEY]
    return nil unless trusted_shape?(marker) && trusted_message?(message, marker)

    marker
  rescue StandardError
    nil
  end

  def trusted_shape?(marker)
    return false unless marker.is_a?(Hash)

    case marker['version']
    when VERSION then trusted_v1_shape?(marker)
    when VERSION_V2 then trusted_v2_shape?(marker)
    else false
    end
  end

  def common(conversation, start_id, end_id, fingerprint)
    {
      'kind' => KIND,
      'source_account_id' => conversation.account_id,
      'source_contact_id' => conversation.contact_id,
      'source_conversation_id' => conversation.id,
      'start_public_message_id' => start_id,
      'end_public_message_id' => end_id,
      'transcript_fingerprint' => fingerprint
    }
  end
  private_class_method :common

  def trusted_v1_shape?(marker)
    exact_keys?(marker, KEYS) && marker['kind'] == KIND && STATES.include?(marker['state']) &&
      marker['generator'] == GENERATOR && common_shape_valid?(marker)
  end
  private_class_method :trusted_v1_shape?

  def trusted_v2_shape?(marker)
    exact_keys?(marker, V2_KEYS) && marker['kind'] == KIND && marker['generator'] == GENERATOR_V2 &&
      TRIGGER_SOURCES.include?(marker['trigger_source']) &&
      marker['memory_signal_version'] == MEMORY_SIGNAL_VERSION && common_shape_valid?(marker)
  end
  private_class_method :trusted_v2_shape?

  def exact_keys?(marker, keys)
    marker.keys.map(&:to_s).sort == keys.sort
  end
  private_class_method :exact_keys?

  def common_shape_valid?(marker)
    identifier_fields(marker).all? { |value| value.is_a?(Integer) && value.positive? } &&
      marker['start_public_message_id'] <= marker['end_public_message_id'] &&
      marker['transcript_fingerprint'].is_a?(String) && FINGERPRINT.match?(marker['transcript_fingerprint'])
  end
  private_class_method :common_shape_valid?

  # rubocop:disable Metrics/CyclomaticComplexity -- Explicit trust predicates are security-sensitive.
  def trusted_message?(message, marker)
    return false unless message.private? && message.outgoing? &&
                        marker['source_account_id'] == message.account_id &&
                        marker['source_conversation_id'] == message.conversation_id &&
                        marker['source_contact_id'] == message.conversation.contact_id

    if marker['version'] == VERSION # preserve the existing v1 trust contract exactly
      return message.sender_type == 'Marine::Assistant' && message.sender_id.present?
    end

    trusted_v2_message?(message, marker)
  end
  private_class_method :trusted_message?
  # rubocop:enable Metrics/CyclomaticComplexity

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- Closed provenance checks stay explicit.
  def trusted_v2_message?(message, marker)
    conversation = message.conversation
    assistant_id = MarineInbox.find_by(inbox_id: conversation.inbox_id)&.marine_assistant_id
    return false unless assistant_id && message.sender_type == 'Marine::Assistant' && message.sender_id == assistant_id

    ids = [marker['start_public_message_id'], marker['end_public_message_id']].uniq
    endpoints = conversation.messages.where(
      id: ids, private: false, message_type: %i[incoming outgoing],
      account_id: conversation.account_id, inbox_id: conversation.inbox_id
    ).order(:id).to_a
    return false unless endpoints.map(&:id) == ids

    start_message = endpoints.first
    end_message = endpoints.last
    start_message.id <= end_message.id && start_message.created_at <= end_message.created_at &&
      end_message.id < message.id && end_message.created_at <= message.created_at
  end
  private_class_method :trusted_v2_message?
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def identifier_fields(marker)
    %w[source_account_id source_contact_id source_conversation_id
       start_public_message_id end_public_message_id].map { |key| marker[key] }
  end
  private_class_method :identifier_fields
end
# rubocop:enable Metrics/ModuleLength
