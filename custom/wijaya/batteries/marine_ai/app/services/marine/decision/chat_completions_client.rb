require 'ruby_llm'

# chat/completions transport for the Marine Decision Maker (Phase 2 / Stage 2). It builds
# an ISOLATED RubyLLM context from the injected Decision settings ONLY (provider/model/
# endpoint/api_key) — it never touches Marine::Llm::Config or BaseService runtime config,
# so the Response Generator is completely unaffected. Timeout is bounded and retries are
# zero for deterministic classifier transport.
#
# It builds no prompts: it forwards a validated conversation plus an optional system
# message, structured schema, and temperature (0 is honored for Stage 3), and returns a
# bounded content String. A structured Hash reply is serialized to JSON verbatim (never
# repaired); nil/other/blank/oversized output fails closed to 'malformed_response'. The
# API key and any raw exception are never placed in the result.
class Marine::Decision::ChatCompletionsClient
  API_MODE = 'chat_completions'.freeze
  REQUEST_TIMEOUT = 20
  MAX_RETRIES = 0

  # The only allowlisted top-level request keys and the only two conversational roles;
  # the system prompt travels via the system: key.
  REQUEST_KEYS = %i[messages system schema temperature].freeze
  MESSAGE_KEYS = %i[role content].freeze
  ROLES = %w[user assistant].freeze

  # Conservative outbound bounds so a hostile/oversized request can never reach the
  # network. Everything below is validated BEFORE any RubyLLM context is built.
  MAX_MESSAGES = 64
  MAX_CONTENT_BYTES = 100_000       # per message content
  MAX_SYSTEM_BYTES = 100_000        # system instruction
  MAX_REQUEST_BYTES = 1_000_000     # whole serialized request
  MAX_SCHEMA_BYTES = 20_000         # serialized schema
  MAX_SCHEMA_DEPTH = 12
  MAX_SCHEMA_KEYS = 200             # keys per schema hash
  MAX_SCHEMA_ARRAY = 200            # items per schema array
  MAX_SCHEMA_STRING = 5_000         # schema string/symbol length
  TEMPERATURE_MIN = 0
  TEMPERATURE_MAX = 2
  # Conservative ceiling so a hostile/oversized provider reply can never ride out.
  MAX_OUTPUT_BYTES = 100_000

  def initialize(provider:, model:, endpoint:, api_key:)
    @provider = provider.to_s
    @model = model.to_s
    @endpoint = endpoint.to_s
    @api_key = api_key.to_s
  end

  def call(request)
    validated = validate_request(request)
    return failure('malformed_response') if validated.nil?

    run(validated)
  rescue StandardError => e
    failure(timeout?(e) ? 'timeout' : 'provider_error')
  end

  private

  # Strictly bound the whole request BEFORE building any RubyLLM context. Unknown or
  # duplicate canonical top-level keys, an out-of-bounds/typed system, schema, or
  # temperature, or an empty/oversized conversation all fail closed to nil (never
  # silently dropped). The caller's input is neither mutated nor frozen.
  def validate_request(request)
    attrs = canonical_attrs(request, REQUEST_KEYS)
    return nil if attrs.nil?

    messages = normalized_messages(attrs[:messages])
    return nil if messages.empty?
    return nil unless valid_system?(attrs[:system]) && valid_schema?(attrs[:schema]) && valid_temperature?(attrs[:temperature])
    return nil unless within_request_bytes?(messages, attrs[:system], attrs[:schema])

    { messages: messages, system: attrs[:system], schema: attrs[:schema], temperature: attrs[:temperature] }
  end

  def run(validated)
    chat = configure(build_chat, validated[:system], validated[:schema], validated[:temperature])
    messages = validated[:messages]
    messages[0...-1].each { |message| chat.add_message(role: message[:role].to_sym, content: message[:content]) }
    finalize(chat.ask(messages.last[:content]), validated[:schema])
  end

  def configure(chat, system, schema, temperature)
    chat.with_instructions(system) if system.present? && chat.respond_to?(:with_instructions)
    chat.with_temperature(temperature) if !temperature.nil? && chat.respond_to?(:with_temperature)
    chat.with_schema(schema) if schema.present? && chat.respond_to?(:with_schema)
    chat
  end

  def finalize(response, schema)
    text = content_text(response&.content, schema)
    return failure('malformed_response') if text.blank? || text.bytesize > MAX_OUTPUT_BYTES

    Marine::Decision::TransportResult.success(payload: text, model: @model, api_mode: API_MODE)
  end

  # A String is returned as-is (never repaired), keeping the schema response UNPARSED at
  # the transport boundary; a structured Hash reply is serialized to JSON only when a
  # schema was requested; anything else fails closed to nil. Serializing a Hash here (and
  # any downstream JSON.parse) may collapse duplicate provider response keys, so Stage 3
  # MUST revalidate the resulting untrusted candidate plan — this transport does not.
  def content_text(content, schema)
    return content if content.is_a?(String)
    return content.to_json if schema.present? && content.is_a?(Hash)

    nil
  end

  def build_chat
    context.chat(model: @model, provider: rubyllm_provider, assume_model_exists: true)
  end

  def rubyllm_provider
    Marine::Llm::ProviderConfig.rubyllm_provider(@provider)
  end

  def context
    RubyLLM.context do |config|
      case rubyllm_provider
      when 'gemini'
        config.gemini_api_key = @api_key
        config.gemini_api_base = api_base
      when 'anthropic'
        config.anthropic_api_key = @api_key
        # RubyLLM 1.15 exposes anthropic_api_base= and appends `v1/messages` itself, so the
        # injected endpoint is configured RAW (no /v1) for consistency with the validated
        # settings; a non-default endpoint is therefore honored, never silently discarded.
        config.anthropic_api_base = anthropic_api_base
      else
        config.openai_api_key = @api_key
        config.openai_api_base = api_base
      end
      config.request_timeout = REQUEST_TIMEOUT
      config.max_retries = MAX_RETRIES
    end
  end

  # OpenAI-compatible base normalization, consistent with the connection test: append /v1
  # unless the endpoint already carries a version segment or an /openai suffix.
  def api_base
    base = @endpoint.chomp('/')
    return base if base.end_with?('/openai') || base.match?(%r{/v\d+(?:beta)?(?:/|$)})

    "#{base}/v1"
  end

  # Anthropic's base is the RAW validated endpoint; the provider appends `v1/messages`.
  def anthropic_api_base
    @endpoint.chomp('/')
  end

  def normalized_messages(messages)
    return [] unless messages.is_a?(Array) && messages.size.between?(1, MAX_MESSAGES)

    normalized = messages.map { |message| normalize_message(message) }
    normalized.include?(nil) ? [] : normalized
  end

  def normalize_message(message)
    attrs = canonical_attrs(message, MESSAGE_KEYS)
    return nil if attrs.nil?

    role = attrs[:role].to_s
    content = attrs[:content]
    return nil unless ROLES.include?(role) && content.is_a?(String) && content.present? && content.bytesize <= MAX_CONTENT_BYTES

    { role: role, content: content }
  end

  # Canonicalize a hash to symbol keys, rejecting (nil) any key that is not a String/Symbol,
  # any key outside the allowlist, and any duplicate canonical String/Symbol key. Never
  # mutates the input.
  def canonical_attrs(hash, allowed)
    return nil unless hash.is_a?(Hash)

    attrs = {}
    hash.each do |key, value|
      return nil unless key.is_a?(String) || key.is_a?(Symbol)

      canonical = key.to_sym
      return nil unless allowed.include?(canonical)
      return nil if attrs.key?(canonical)

      attrs[canonical] = value
    end
    attrs
  end

  # system is optional; when present it must be a String within the byte bound.
  def valid_system?(system)
    return true if system.nil?

    system.is_a?(String) && system.bytesize <= MAX_SYSTEM_BYTES
  end

  # schema is optional; when present it must be a Hash within recursive structural bounds
  # and a serialized-size ceiling.
  def valid_schema?(schema)
    return true if schema.nil?
    return false unless schema.is_a?(Hash) && schema_bounded?(schema, 1)

    serialized_bytes(schema) <= MAX_SCHEMA_BYTES
  end

  def schema_bounded?(value, depth)
    return false if depth > MAX_SCHEMA_DEPTH

    case value
    when Hash then bounded_schema_hash?(value, depth)
    when Array then bounded_schema_array?(value, depth)
    else schema_leaf?(value)
    end
  end

  def bounded_schema_hash?(hash, depth)
    hash.size <= MAX_SCHEMA_KEYS && hash.all? { |key, child| schema_key?(key) && schema_bounded?(child, depth + 1) }
  end

  def bounded_schema_array?(array, depth)
    array.size <= MAX_SCHEMA_ARRAY && array.all? { |child| schema_bounded?(child, depth + 1) }
  end

  def schema_key?(key)
    (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s.length <= MAX_SCHEMA_STRING
  end

  def schema_leaf?(value)
    case value
    when String, Symbol then value.to_s.length <= MAX_SCHEMA_STRING
    when Numeric, true, false, nil then true
    else false
    end
  end

  # temperature is optional; when present it must be a real, finite Numeric in range.
  def valid_temperature?(temperature)
    return true if temperature.nil?
    return false unless temperature.is_a?(Numeric) && temperature.real?
    return false if temperature.respond_to?(:finite?) && !temperature.finite?

    temperature.between?(TEMPERATURE_MIN, TEMPERATURE_MAX)
  end

  # Final ceiling on the whole serialized request so many in-bounds parts can't sum past it.
  def within_request_bytes?(messages, system, schema)
    serialized_bytes(messages: messages, system: system, schema: schema) <= MAX_REQUEST_BYTES
  end

  def serialized_bytes(value)
    value.to_json.bytesize
  rescue StandardError
    Float::INFINITY
  end

  def failure(reason)
    Marine::Decision::TransportResult.failure(reason: reason, api_mode: API_MODE, model: @model)
  end

  # Classify by exception TYPE only (never the message) so a slow-network timeout maps to
  # the 'timeout' reason while nothing else leaks.
  def timeout?(error)
    error.is_a?(Timeout::Error) || error.class.name.to_s.match?(/Timeout/i)
  end
end
