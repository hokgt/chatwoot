# Reads and writes Marine's two independent LLM provider configurations on top of
# InstallationConfig, exposing a single allowlisted contract to the controller so
# JSON parsing and key names never leak into request code.
#
#   :response_generator — the LIVE runtime configuration. Maps to the legacy
#     MARINE_LLM_PROVIDER / MARINE_OPEN_AI_* keys the unchanged message runner
#     already reads, so saving it keeps runtime behavior in step (via
#     Marine::Llm::Config / Marine::Llm::ProviderConfig, which are untouched).
#   :decision_maker — dedicated MARINE_DECISION_LLM_* keys. NOT yet wired into
#     runtime. Each field falls back to the response_generator value when its own
#     key is unset, so a fresh install shows the same effective config in both
#     cards until the decision maker is configured independently. The api_key
#     fallback is a ONE-TIME seed: saving the decision maker without an explicit
#     key materializes the current effective key into MARINE_DECISION_LLM_API_KEY
#     so later response-generator changes never silently retarget it.
#
# The raw API key never leaves this layer except through #config/#api_key (used
# only by ConnectionTestService); #to_view returns a masked preview and a
# presence flag, never plaintext. Embedding config (MARINE_EMBEDDING_MODEL) is
# intentionally out of scope here and is left untouched.
class Marine::Llm::SettingsStore
  TARGETS = %i[decision_maker response_generator].freeze
  WRITABLE_FIELDS = %i[provider model endpoint api_key].freeze

  RESPONSE_KEYS = {
    provider: 'MARINE_LLM_PROVIDER',
    model: 'MARINE_OPEN_AI_MODEL',
    endpoint: 'MARINE_OPEN_AI_ENDPOINT',
    api_key: 'MARINE_OPEN_AI_API_KEY'
  }.freeze

  DECISION_KEYS = {
    provider: 'MARINE_DECISION_LLM_PROVIDER',
    model: 'MARINE_DECISION_LLM_MODEL',
    endpoint: 'MARINE_DECISION_LLM_ENDPOINT',
    api_key: 'MARINE_DECISION_LLM_API_KEY'
  }.freeze

  KEY_MAP = { response_generator: RESPONSE_KEYS, decision_maker: DECISION_KEYS }.freeze

  class << self
    def target?(target)
      TARGETS.include?(target.to_s.to_sym)
    end

    def for(target)
      raise ArgumentError, "unknown Marine LLM target: #{target}" unless target?(target)

      new(target.to_s.to_sym)
    end
  end

  def initialize(target)
    @target = target
    @keys = KEY_MAP.fetch(target)
  end

  # Effective values with decision-maker fallback already applied.
  def config
    @config ||= @target == :response_generator ? response_config : decision_config
  end

  def provider
    config[:provider]
  end

  def model
    config[:model]
  end

  def endpoint
    config[:endpoint]
  end

  def api_key
    config[:api_key]
  end

  # UI-facing view: masked key + presence + provider metadata. Never plaintext.
  def to_view
    {
      provider: config[:provider],
      provider_label: Marine::Llm::ProviderConfig.provider_info(config[:provider])[:label],
      model: config[:model],
      api_endpoint: config[:endpoint],
      api_key_masked: mask(config[:api_key]),
      api_key_present: config[:api_key].present?,
      supports_embeddings: Marine::Llm::ProviderConfig.supports_embeddings?(config[:provider]),
      configured: config[:api_key].present?,
      api_key_inherited: api_key_inherited?
    }
  end

  # Persists only the allowlisted, present fields. A blank/omitted api_key keeps
  # the existing stored key; endpoint/model are persisted whenever the key is
  # present so an explicit clear is honored. The caller wraps both targets in a
  # single transaction for atomicity.
  #
  # For the decision maker a blank/omitted api_key additionally seeds its own key
  # from the current effective fallback (once), so the two configs become truly
  # independent — see #seed_decision_api_key.
  def write(attrs)
    attrs = attrs.to_h.symbolize_keys
    persist(:provider, attrs[:provider]) if attrs[:provider].present?
    persist(:model, attrs[:model]) if attrs.key?(:model)
    persist(:endpoint, attrs[:endpoint]) if attrs.key?(:endpoint)

    if attrs[:api_key].present?
      persist(:api_key, attrs[:api_key])
    elsif @target == :decision_maker
      seed_decision_api_key
    end
  end

  private

  # True when the decision maker has no key of its own and is reading through the
  # response-generator fallback — used by the UI to label the key as inherited.
  def api_key_inherited?
    return false unless @target == :decision_maker

    decision_value(:api_key).blank? && config[:api_key].present?
  end

  # Materialize the decision maker's key from the current effective fallback the
  # first time it is saved without an explicit key. Reads the CURRENT response
  # key (the controller writes the decision maker BEFORE the response generator,
  # so a same-request response change is not yet visible and cannot leak in). If
  # a decision-specific key already exists it is preserved; with no fallback key
  # nothing is written, so we never create a blank key row.
  def seed_decision_api_key
    return if decision_value(:api_key).present?

    fallback = Marine::Llm::Config.api_key
    persist(:api_key, fallback) if fallback.present?
  end

  # The response generator IS the legacy runtime config; delegate to the existing
  # (untouched) Config/ProviderConfig so defaults and validation stay identical.
  def response_config
    {
      provider: Marine::Llm::ProviderConfig.provider,
      model: Marine::Llm::Config.model,
      endpoint: Marine::Llm::Config.endpoint,
      api_key: Marine::Llm::Config.api_key
    }
  end

  def decision_config
    base = response_config
    {
      provider: normalize_provider(decision_value(:provider).presence || base[:provider]),
      model: decision_value(:model).presence || base[:model],
      endpoint: decision_value(:endpoint).presence || base[:endpoint],
      api_key: decision_value(:api_key).presence || base[:api_key]
    }
  end

  def decision_value(field)
    Marine::Llm::Config.installation_value(DECISION_KEYS.fetch(field))
  end

  def normalize_provider(value)
    Marine::Llm::ProviderConfig::PROVIDERS.key?(value) ? value : Marine::Llm::ProviderConfig::DEFAULT_PROVIDER
  end

  def persist(field, value)
    config = InstallationConfig.where(name: @keys.fetch(field)).first_or_initialize
    config.value = value
    config.locked = false
    config.save!
  end

  def mask(key)
    return nil if key.blank?
    return '••••' if key.length <= 10

    "#{key[0, 6]}...#{key[-4, 4]}"
  end
end
