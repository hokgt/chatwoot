# Marine LLM provider registry. Keeps the list of supported AI providers plus the
# metadata needed to talk to each one (label, default endpoint/model, the RubyLLM
# provider adapter to use, and whether embeddings are available). The active
# provider is read from the MARINE_LLM_PROVIDER InstallationConfig, defaulting to
# 'openai'. Never falls back to any CAPTAIN_* config.
module Marine::Llm::ProviderConfig
  DEFAULT_PROVIDER = 'openai'.freeze

  PROVIDERS = {
    'openai' => {
      label: 'OpenAI', default_endpoint: 'https://api.openai.com', default_model: 'gpt-4.1-mini',
      rubyllm_provider: 'openai', supports_embeddings: true
    },
    'openrouter' => {
      label: 'OpenRouter', default_endpoint: 'https://openrouter.ai/api', default_model: 'nvidia/nemotron-3-ultra-550b-a55b:free',
      rubyllm_provider: 'openai', supports_embeddings: false
    },
    'gemini' => {
      label: 'Google Gemini', default_endpoint: 'https://generativelanguage.googleapis.com/v1beta/openai', default_model: 'gemini-2.0-flash',
      rubyllm_provider: 'openai', supports_embeddings: true
    },
    'anthropic' => {
      label: 'Anthropic Claude', default_endpoint: 'https://api.anthropic.com', default_model: 'claude-sonnet-4-20250514',
      rubyllm_provider: 'anthropic', supports_embeddings: false
    },
    'custom' => {
      label: 'Custom (OpenAI-compatible)', default_endpoint: '', default_model: '',
      rubyllm_provider: 'openai', supports_embeddings: true
    }
  }.freeze

  module_function

  def provider
    value = Marine::Llm::Config.installation_value('MARINE_LLM_PROVIDER').presence
    PROVIDERS.key?(value) ? value : DEFAULT_PROVIDER
  end

  def provider_info(name = provider)
    PROVIDERS[name] || PROVIDERS[DEFAULT_PROVIDER]
  end

  def rubyllm_provider(name = provider)
    provider_info(name)[:rubyllm_provider]
  end

  def supports_embeddings?(name = provider)
    provider_info(name)[:supports_embeddings]
  end

  # Serializable list for the admin UI dropdown.
  def available_providers
    PROVIDERS.map do |key, info|
      {
        value: key,
        label: info[:label],
        default_endpoint: info[:default_endpoint],
        default_model: info[:default_model],
        supports_embeddings: info[:supports_embeddings]
      }
    end
  end
end
