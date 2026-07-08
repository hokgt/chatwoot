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
  def complete(prompt:, system: nil, **options)
    chat(messages: [{ role: 'user', content: prompt }], system: system, **options)
  end

  # messages: array of { role:, content: } (string or symbol keys). An optional
  # system message can be supplied either inline in messages or via the system:
  # keyword; the keyword wins when both are present.
  def chat(messages:, system: nil, model: nil, temperature: nil)
    resolved_model = model.presence || self.model
    return not_configured_result(resolved_model) unless configured?

    conversation = normalize_messages(messages)
    system_content = system.presence || extract_system(messages)
    return no_messages_result(resolved_model) if conversation.empty?

    run_chat(resolved_model, conversation, system_content, temperature)
  rescue StandardError => e
    capture(e)
    error_result(e.message, resolved_model)
  end

  private

  attr_reader :account

  def run_chat(resolved_model, conversation, system_content, temperature)
    chat = build_chat(resolved_model)
    chat.with_instructions(system_content) if system_content.present?
    chat.with_temperature(temperature) if temperature && chat.respond_to?(:with_temperature)

    conversation[0...-1].each do |message|
      chat.add_message(role: message[:role].to_sym, content: message[:content])
    end

    response = chat.ask(conversation.last[:content])
    success_result(response, resolved_model)
  end

  def build_chat(resolved_model)
    context.chat(model: resolved_model, provider: 'openai', assume_model_exists: true)
  end

  def context
    @context ||= RubyLLM.context do |config|
      config.openai_api_key = api_key
      config.openai_api_base = api_base
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

  def success_result(response, resolved_model)
    { ok: true, message: response.content, error: nil, raw: response, model: resolved_model }
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
