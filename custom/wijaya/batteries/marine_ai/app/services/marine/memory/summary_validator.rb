# frozen_string_literal: true

require 'json'

# Strictly validates raw provider envelopes. Semantic memory eligibility is decided
# only by the bounded second-provider verdict in ContactNotesService.
class Marine::Memory::SummaryValidator
  MAX_ENVELOPE_BYTES = 5000
  MAX_JUDGE_VERDICT_BYTES = 5000
  MAX_SUMMARY_CHARS = 1200
  GENERATOR_KEYS = %w[has_durable_memory summary].freeze
  VERDICT_KEYS = %w[has_dynamic_product_facts is_durable is_generic is_indonesian].freeze
  BOOLEAN_VALUES = [true, false].freeze

  Result = Struct.new(:summary, :reason, keyword_init: true) do
    def valid?
      reason.nil?
    end
  end

  Verdict = Struct.new(:accepted, :reason, keyword_init: true) do
    def accepted?
      accepted
    end
  end

  def validate(payload)
    validate_envelope(strict_parse(payload, max_bytes: MAX_ENVELOPE_BYTES))
  rescue JSON::ParserError, EncodingError, ArgumentError
    invalid('invalid_json')
  rescue StandardError
    invalid('validation_failed')
  end

  def validate_verdict(payload)
    parsed = strict_parse(payload, max_bytes: MAX_JUDGE_VERDICT_BYTES)
    return rejected('invalid_verdict_shape') unless parsed.instance_of?(Hash) && parsed.keys.sort == VERDICT_KEYS.sort
    return rejected('invalid_verdict_types') unless VERDICT_KEYS.all? { |key| BOOLEAN_VALUES.include?(parsed[key]) }
    return rejected('rejected_verdict') unless parsed == {
      'is_indonesian' => true,
      'is_durable' => true,
      'is_generic' => false,
      'has_dynamic_product_facts' => false
    }

    Verdict.new(accepted: true, reason: nil).freeze
  rescue JSON::ParserError, EncodingError, ArgumentError
    rejected('invalid_verdict_json')
  rescue StandardError
    rejected('verdict_validation_failed')
  end

  private

  def strict_parse(payload, max_bytes:)
    raise JSON::ParserError, 'invalid envelope type' unless payload.is_a?(String)
    raise JSON::ParserError, 'invalid encoding' unless valid_utf8?(payload)
    raise JSON::ParserError, 'envelope too large' if payload.bytesize > max_bytes

    JSON.parse(payload, create_additions: false, allow_duplicate_key: false)
  end

  def validate_envelope(parsed)
    return invalid('invalid_shape') unless parsed.instance_of?(Hash) && parsed.keys.sort == GENERATOR_KEYS.sort
    return invalid('invalid_has_durable_memory') unless [true, false].include?(parsed['has_durable_memory'])
    return validate_empty(parsed['summary']) unless parsed['has_durable_memory']

    validate_summary(parsed['summary'])
  end

  def validate_empty(summary)
    return invalid('invalid_false_summary') unless summary.nil?

    invalid('no_durable_memory')
  end

  def validate_summary(value)
    return invalid('invalid_summary_type') unless value.is_a?(String) && valid_utf8?(value)

    summary = value.strip
    return invalid('blank_summary') if summary.empty?
    return invalid('summary_too_long') if summary.length > MAX_SUMMARY_CHARS

    Result.new(summary: summary, reason: nil).freeze
  end

  def valid_utf8?(value)
    value.dup.force_encoding(Encoding::UTF_8).valid_encoding?
  end

  def invalid(reason)
    Result.new(summary: nil, reason: reason).freeze
  end

  def rejected(reason)
    Verdict.new(accepted: false, reason: reason).freeze
  end
end
