# Marine keeps its LLM credentials fully independent from Captain. Every value is
# read from MARINE_* InstallationConfig keys only, never CAPTAIN_* keys, so Marine
# can target a different provider/model/endpoint without touching Captain AI.
module Marine::Llm::Config
  DEFAULT_MODEL = 'gpt-4.1-mini'.freeze
  DEFAULT_ENDPOINT = 'https://api.openai.com'.freeze
  DEFAULT_EMBEDDING_MODEL = 'text-embedding-3-small'.freeze

  module_function

  def api_key
    installation_value('MARINE_OPEN_AI_API_KEY')
  end

  def model
    installation_value('MARINE_OPEN_AI_MODEL').presence || DEFAULT_MODEL
  end

  def endpoint
    installation_value('MARINE_OPEN_AI_ENDPOINT').presence || DEFAULT_ENDPOINT
  end

  def embedding_model
    installation_value('MARINE_EMBEDDING_MODEL').presence || DEFAULT_EMBEDDING_MODEL
  end

  def provider
    Marine::Llm::ProviderConfig.provider
  end

  def rubyllm_provider
    Marine::Llm::ProviderConfig.rubyllm_provider
  end

  # OpenAI-compatible endpoints expect the versioned base (/v1). Some providers
  # (e.g. Gemini's OpenAI-compat endpoint) already carry a version segment, so we
  # avoid appending a second /v1.
  def api_base
    base = endpoint.chomp('/')
    return base if base.end_with?('/openai') || base.match?(%r{/v\d+(?:beta)?(?:/|$)})

    "#{base}/v1"
  end

  def configured?
    api_key.present?
  end

  def installation_value(name)
    InstallationConfig.find_by(name: name)&.value.to_s
  end
end
