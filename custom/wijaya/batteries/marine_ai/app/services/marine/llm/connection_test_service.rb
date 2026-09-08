require 'ruby_llm'

# Validates a set of Marine LLM credentials before an admin commits them. Builds a
# throwaway RubyLLM context from the supplied provider/key/endpoint/model, sends a
# minimal prompt with a short timeout, and returns a normalized result hash. The
# API key is never placed in the result or logged.
#
#   { ok:, message:, error: }
class Marine::Llm::ConnectionTestService
  TEST_TIMEOUT = 5
  TEST_PROMPT = 'ping'.freeze

  def initialize(provider:, api_key:, endpoint: nil, model: nil)
    @provider = provider.to_s.presence || Marine::Llm::ProviderConfig::DEFAULT_PROVIDER
    @api_key = api_key.to_s
    @endpoint = endpoint.to_s
    @model = model.to_s
  end

  def call
    return failure('API key is required') if @api_key.blank?
    return failure('Model is required') if resolved_model.blank?

    chat = context.chat(model: resolved_model, provider: rubyllm_provider, assume_model_exists: true)
    response = chat.ask(TEST_PROMPT)
    success(response.content)
  rescue StandardError => e
    failure(e.message)
  end

  private

  def provider_info
    @provider_info ||= Marine::Llm::ProviderConfig.provider_info(@provider)
  end

  def rubyllm_provider
    provider_info[:rubyllm_provider]
  end

  def resolved_model
    @model.presence || provider_info[:default_model].to_s
  end

  def endpoint
    @endpoint.presence || provider_info[:default_endpoint].to_s
  end

  def api_base
    base = endpoint.chomp('/')
    return base if base.end_with?('/openai') || base.match?(%r{/v\d+(?:beta)?(?:/|$)})

    "#{base}/v1"
  end

  def context
    RubyLLM.context do |config|
      case rubyllm_provider
      when 'gemini'
        config.gemini_api_key = @api_key
        config.gemini_api_base = api_base
      when 'anthropic'
        config.anthropic_api_key = @api_key
      else
        config.openai_api_key = @api_key
        config.openai_api_base = api_base
      end
      config.request_timeout = TEST_TIMEOUT
      config.max_retries = 0
    end
  end

  def success(message)
    { ok: true, message: message.to_s.truncate(200), error: nil }
  end

  def failure(error)
    { ok: false, message: nil, error: error.to_s }
  end
end
