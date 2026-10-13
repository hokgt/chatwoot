# frozen_string_literal: true

# Default provider-backed generator for the trusted-memory re-engagement reply. The composer
# owns the control contract and every safety gate; this class only performs the configured
# Model-2 chat call through a strict { "reply": <string> } envelope (the same request-side
# shape the grounded product wording service uses) and returns the extracted reply STRING or
# nil. The returned text is always UNTRUSTED and is fully re-gated by the composer; a wrong
# envelope shape, unparseable output, or provider failure fails closed to nil.
#
# Injectable: tests (and only tests) supply a callable in `generator:` to the composer, which
# receives the same closed arguments and plays the provider.
class Marine::Memory::Reengagement::Generator
  REPLY_SCHEMA = {
    name: 'memory_reengagement_reply',
    strict: true,
    schema: {
      type: 'object',
      additionalProperties: false,
      required: %w[reply],
      properties: { 'reply' => { 'type' => 'string' } }
    }
  }.freeze

  def initialize(account:, service: nil)
    @account = account
    @service = service || Marine::Llm::BaseService.new(account: account)
  end

  # Returns the untrusted candidate reply String, or nil on any provider/shape failure.
  def call(system:, messages:, temperature:)
    result = @service.chat(messages: messages, system: system,
                           temperature: temperature, schema: REPLY_SCHEMA)
    return nil unless result[:ok] && result[:message].present?

    reply_from_envelope(result[:message])
  end

  private

  # Parse the provider's { "reply": <string> } envelope as an EXACT object — no fence
  # stripping or repair. Anything non-conforming fails closed to nil.
  def reply_from_envelope(raw)
    return nil unless raw.is_a?(String) && raw.valid_encoding?

    parsed = JSON.parse(raw, allow_duplicate_key: false)
    return nil unless parsed.is_a?(Hash) && parsed.keys == %w[reply]
    return nil unless parsed['reply'].is_a?(String)

    parsed['reply']
  rescue JSON::ParserError
    nil
  end
end
