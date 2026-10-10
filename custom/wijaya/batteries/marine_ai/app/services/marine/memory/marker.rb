# frozen_string_literal: true

# Closed provenance contract for Marine-authored long-term-memory private notes.
# A note is trusted only when every field matches this exact, versioned shape and
# the note itself is a private outgoing Message on the declared source conversation.
module Marine::Memory::Marker
  KEY = 'wijaya_marine_memory'
  VERSION = 1
  KIND = 'marine_long_term_memory'
  GENERATOR = 'marine_llm_v1'
  STATES = %w[checkpoint final].freeze
  KEYS = %w[version kind state source_account_id source_contact_id source_conversation_id
            start_public_message_id end_public_message_id transcript_fingerprint generator].freeze
  FINGERPRINT = /\A[0-9a-f]{64}\z/

  module_function

  def build(state:, conversation:, start_id:, end_id:, fingerprint:)
    {
      'version' => VERSION,
      'kind' => KIND,
      'state' => state,
      'source_account_id' => conversation.account_id,
      'source_contact_id' => conversation.contact_id,
      'source_conversation_id' => conversation.id,
      'start_public_message_id' => start_id,
      'end_public_message_id' => end_id,
      'transcript_fingerprint' => fingerprint,
      'generator' => GENERATOR
    }
  end

  def extract(message)
    marker = message.additional_attributes.to_h[KEY]
    return nil unless trusted_shape?(marker) && trusted_message?(message, marker)

    marker
  rescue StandardError
    nil
  end

  def trusted_shape?(marker)
    marker.is_a?(Hash) && exact_keys?(marker) && metadata_valid?(marker) &&
      identifiers_valid?(marker) && range_valid?(marker) && fingerprint_valid?(marker)
  end

  def exact_keys?(marker)
    marker.keys.map(&:to_s).sort == KEYS.sort
  end
  private_class_method :exact_keys?

  def metadata_valid?(marker)
    marker['version'] == VERSION && marker['kind'] == KIND &&
      STATES.include?(marker['state']) && marker['generator'] == GENERATOR
  end
  private_class_method :metadata_valid?

  def identifiers_valid?(marker)
    identifier_fields(marker).all? { |value| value.is_a?(Integer) && value.positive? }
  end
  private_class_method :identifiers_valid?

  def range_valid?(marker)
    marker['start_public_message_id'] <= marker['end_public_message_id']
  end
  private_class_method :range_valid?

  def fingerprint_valid?(marker)
    marker['transcript_fingerprint'].is_a?(String) && FINGERPRINT.match?(marker['transcript_fingerprint'])
  end
  private_class_method :fingerprint_valid?

  def trusted_message?(message, marker)
    message.private? && message.outgoing? &&
      message.sender_type == 'Marine::Assistant' && message.sender_id.present? &&
      marker['source_account_id'] == message.account_id &&
      marker['source_conversation_id'] == message.conversation_id &&
      marker['source_contact_id'] == message.conversation.contact_id
  end
  private_class_method :trusted_message?

  def identifier_fields(marker)
    %w[source_account_id source_contact_id source_conversation_id
       start_public_message_id end_public_message_id].map { |key| marker[key] }
  end
  private_class_method :identifier_fields
end
