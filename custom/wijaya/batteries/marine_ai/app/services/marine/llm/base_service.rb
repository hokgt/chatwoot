require 'ruby_llm'

# Foundation for every Marine LLM call. It builds an isolated RubyLLM context from
# Marine-specific credentials (never Captain's), targets an OpenAI-compatible
# endpoint, and always returns a normalized result hash so callers never have to
# rescue RubyLLM internals themselves.
#
#   { ok:, message:, error:, raw:, model: }
#
# API keys are never placed in the result or logged.
class Marine::Llm::BaseService
  REQUEST_TIMEOUT = 30
  MAX_RETRIES = 1

  def initialize(account: nil, model: nil, api_key: nil, api_base: nil)
    @account = account
    @model_override = model.presence
    @api_key_override = api_key.presence
    @api_base_override = api_base.presence
  end

  def configured?
    @api_key_override.present? || Marine::Llm::Config.configured?
  end

  def model
    @model_override || Marine::Llm::Config.model
  end

  # Convenience wrapper for a single-shot prompt with an optional system message.
  def complete(prompt:, system: nil, **)
    chat(messages: [{ role: 'user', content: prompt }], system: system, **)
  end

  # messages: array of { role:, content: } (string or symbol keys). An optional
  # system message can be supplied either inline in messages or via the system:
  # keyword; the keyword wins when both are present.
  #
  # schema: an optional JSON Schema hash (RubyLLM #with_schema format). When given AND
  # the underlying RubyLLM chat supports it, the provider is asked to enforce structured
  # output constrained to that schema (e.g. OpenAI response_format json_schema). This is
  # opt-in: callers that omit schema: are completely unaffected. It is also fail-safe —
  # if the installed RubyLLM cannot enforce schemas, or the provider rejects/ignores the
  # request, the call still returns a normalized result and the caller's own parsing
  # decides acceptance. When schema: is given the returned message is a raw String (structured
  # output is serialized back to its JSON text) so callers keep parsing it themselves; when schema:
  # is omitted the content is returned untouched. Note RubyLLM parses the structured reply before
  # this serialization, so top-level duplicate keys are already collapsed — see #message_text.
  def chat(messages:, system: nil, model: nil, temperature: nil, schema: nil)
    resolved_model = model.presence || self.model
    return not_configured_result(resolved_model) unless configured?

    conversation = normalize_messages(messages)
    system_content = system.presence || extract_system(messages)
    return no_messages_result(resolved_model) if conversation.empty?

    run_chat(resolved_model, conversation, system_content, temperature, schema)
  rescue StandardError => e
    capture(e)
    error_result(e.message, resolved_model)
  end

  private

  attr_reader :account

  def run_chat(resolved_model, conversation, system_content, temperature, schema)
    chat = build_chat(resolved_model)
    chat.with_instructions(system_content) if system_content.present?
    chat.with_temperature(temperature) if temperature && chat.respond_to?(:with_temperature)
    chat.with_schema(schema) if schema && chat.respond_to?(:with_schema)

    conversation[0...-1].each do |message|
      chat.add_message(role: message[:role].to_sym, content: message[:content])
    end

    response = chat.ask(conversation.last[:content])
    success_result(response, resolved_model, schema)
  end

  def build_chat(resolved_model)
    context.chat(model: resolved_model, provider: Marine::Llm::Config.rubyllm_provider, assume_model_exists: true)
  end

  def context
    @context ||= RubyLLM.context do |config|
      case Marine::Llm::Config.rubyllm_provider
      when 'gemini'
        config.gemini_api_key = api_key
        config.gemini_api_base = api_base
      when 'anthropic'
        config.anthropic_api_key = api_key
      else
        config.openai_api_key = api_key
        config.openai_api_base = api_base
      end
      config.request_timeout = REQUEST_TIMEOUT
      config.max_retries = MAX_RETRIES
    end
  end

  def api_key
    @api_key ||= @api_key_override || Marine::Llm::Config.api_key
  end

  def api_base
    @api_base_override || Marine::Llm::Config.api_base
  end

  def normalize_messages(messages)
    Array(messages).filter_map do |message|
      role = message_role(message)
      content = message_content(message)
      next if role == 'system' || content.blank?

      { role: role.presence || 'user', content: content }
    end
  end

  def extract_system(messages)
    system_message = Array(messages).find { |message| message_role(message) == 'system' }
    system_message && message_content(system_message)
  end

  def message_role(message)
    (message[:role] || message['role']).to_s
  end

  def message_content(message)
    (message[:content] || message['content']).to_s
  end

  def success_result(response, resolved_model, schema)
    { ok: true, message: message_text(response.content, schema), error: nil, raw: response, model: resolved_model }
  end

  # Non-schema callers get response.content back untouched — String verbatim, nil stays nil, any
  # other type exactly as RubyLLM returned it — so nothing changes for callers that omit schema:.
  # On the schema path RubyLLM has ALREADY eagerly JSON.parse'd the provider's structured reply into
  # a Hash before this method runs; that parse silently collapses any duplicate TOP-LEVEL keys (last
  # value wins), so the Hash — and the JSON text we reserialize it to here — is faithful to the parsed
  # structure but is NOT a byte-for-byte copy of the provider's original output. A caller that needs
  # duplicate-key-sensitive validation therefore cannot rely on the top level of this text; it must
  # carry that payload as a JSON *string* value, which RubyLLM does not descend into and which survives
  # verbatim (Marine::Charge::FactPreservationValidator does exactly this with its verdict envelope).
  # Structured output that RubyLLM could not parse stays a String and is passed through verbatim (never
  # repaired), so the caller's parser still sees — and rejects — it unrepaired. Any other schema-path
  # type fails closed to nil, which the fail-closed caller treats as a rejected (non-present) message.
  def message_text(content, schema)
    return content unless schema
    return content if content.is_a?(String)
    return content.to_json if content.is_a?(Hash)

    nil
  end

  def error_result(error, resolved_model)
    { ok: false, message: nil, error: error, raw: nil, model: resolved_model }
  end

  def not_configured_result(resolved_model)
    error_result('Marine LLM is not configured', resolved_model)
  end

  def no_messages_result(resolved_model)
    error_result('No conversation messages provided', resolved_model)
  end

  def capture(exception)
    return unless account

    ChatwootExceptionTracker.new(exception, account: account).capture_exception
  end
end
