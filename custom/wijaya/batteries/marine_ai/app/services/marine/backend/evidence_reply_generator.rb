require 'json'

# Langkah 3 (Evidence Packet -> Model 2 SHADOW) — the concrete generator adapter the
# EvidencePacketPresenter injects on the generated wording path. It is the callable
# `#call(system:, messages:) -> String | nil` the presenter expects, implemented over the EXISTING
# Response Generator configuration (Marine::Llm::BaseService + the default MARINE_OPEN_AI_* config);
# it creates NO new provider/model/endpoint and holds no hardcoded credentials.
#
# It asks the provider to enforce a strict one-field { "reply": <string> } envelope (RubyLLM
# #with_schema format), at temperature 0, then parses that envelope EXACTLY — no fence stripping,
# extraction, or repair — and returns the reply body as a plain String, byte-bounded. ANY
# unconfigured/error/malformed/oversize/blank/wrong-envelope/duplicate-key/non-string outcome returns
# nil, so the presenter fails closed to its deterministic fallback. It performs no DB/state access and
# never logs the prompt, messages, provider response, or reply.
class Marine::Backend::EvidenceReplyGenerator
  # Provider-enforced generation envelope: a bare object carrying EXACTLY one string field, "reply".
  # Constraining generation to structured output removes the fenced/markdown/prose SHAPE variance the
  # presenter's downstream gates would otherwise reject. It is a REQUEST-side control only; a provider
  # that ignores or cannot enforce the schema degrades to a fail-closed nil (see #reply_from_envelope).
  REPLY_SCHEMA = {
    name: 'evidence_reply',
    strict: true,
    schema: {
      type: 'object',
      additionalProperties: false,
      required: %w[reply],
      properties: { 'reply' => { type: 'string' } }
    }
  }.freeze

  # A generated reply is at most a couple of short paragraphs; anything larger is malformed and fails
  # closed here (mirrors Marine::Backend::PostGenerationFactValidator::MAX_CANDIDATE_BYTES).
  MAX_REPLY_BYTES = 2000

  def initialize(account: nil)
    @account = account
  end

  # system:   the packet-only system prompt built by EvidencePromptBuilder.
  # messages: the bounded canonical conversation ({ role:, content: } turns + the latest request).
  # Returns the generated reply String, or nil on any unconfigured/error/malformed outcome.
  def call(system:, messages:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent fail-closed guards
    return nil unless system.is_a?(String) && system.strip.present?
    return nil unless messages.is_a?(Array) && !messages.empty?

    service = Marine::Llm::BaseService.new(account: @account)
    return nil unless service.configured?

    result = service.chat(messages: messages, system: system, temperature: 0.0, schema: REPLY_SCHEMA)
    return nil unless result[:ok] && result[:message].present?

    reply_from_envelope(result[:message])
  rescue StandardError
    nil
  end

  private

  # Parse the provider's { "reply": <string> } envelope as an EXACT object. Returns the reply body
  # ONLY for a bare Hash whose sole key is "reply" with a non-blank String value within the byte
  # ceiling; a wrong shape/key/type, an ambiguous duplicate key (rejected by allow_duplicate_key:
  # false), invalid encoding, an oversized body, or any unparseable text fails closed to nil.
  def reply_from_envelope(raw) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent fail-closed guards
    return nil unless raw.is_a?(String) && raw.valid_encoding?

    parsed = JSON.parse(raw, allow_duplicate_key: false)
    return nil unless parsed.is_a?(Hash) && parsed.keys == %w[reply]

    reply = parsed['reply']
    return nil unless reply.is_a?(String)
    return nil if reply.strip.empty? || reply.bytesize > MAX_REPLY_BYTES

    reply
  rescue JSON::ParserError
    nil
  end
end
