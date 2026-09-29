require 'uri'

# Settings-bound facade for the battery-local Marine Decision Maker transport
# (Phase 2 / Stage 2 — production-capable but UNWIRED). It reads ONLY
# Marine::Llm::SettingsStore.for(:decision_maker) (injectable in tests), validates the
# configuration BEFORE any network call, selects a transport SOLELY from the
# allowlisted api_mode, and hands the transport a single bounded protocol request.
#
# It NEVER reads the Response Generator config (Marine::Llm::Config / BaseService); the
# decision settings already apply their own backward-compatible fallback. Every failure
# path returns a sanitized Marine::Decision::TransportResult carrying only an allowlisted
# opaque reason — no key, body, or exception text. This is a transport facade only: it
# builds no prompts, touches no DB/catalog/state, and is wired to no runtime hook.
#
#   chat_completions    request keys: messages, system, schema, temperature
#   openrouter_decisions request keys: questions, state
#
# Unknown or mixed protocol keys are rejected fail-closed; arbitrary provider fields
# are never forwarded.
class Marine::Decision::Client
  CHAT_KEYS = %i[messages system schema temperature].freeze
  DECISIONS_KEYS = %i[questions state].freeze

  def initialize(settings: nil)
    @settings = settings || Marine::Llm::SettingsStore.for(:decision_maker)
  end

  def call(request)
    # Fail-closed completeness: every settings read, config check, transport construction
    # and dispatch runs inside this begin so ANY exception folds to an opaque provider_error
    # instead of escaping. `mode` is captured once; the rescue never re-invokes a fragile
    # settings getter and only echoes an allowlisted mode (else nil).
    mode = nil
    mode = @settings.api_mode
    return failure('unconfigured', nil) unless Marine::Llm::SettingsStore::API_MODES.include?(mode)
    return failure('unconfigured', mode) unless config_valid?

    normalized = filter_request(mode, request)
    return failure('malformed_response', mode) if normalized.nil?

    dispatch(mode, normalized)
  rescue StandardError
    failure('provider_error', allowlisted_mode(mode))
  end

  private

  def allowlisted_mode(mode)
    Marine::Llm::SettingsStore::API_MODES.include?(mode) ? mode : nil
  end

  def dispatch(mode, request)
    if mode == 'openrouter_decisions'
      Marine::Decision::OpenrouterDecisionsClient.new(
        model: @settings.model, endpoint: @settings.endpoint, api_key: @settings.api_key
      ).call(request)
    else
      Marine::Decision::ChatCompletionsClient.new(
        provider: @settings.provider, model: @settings.model,
        endpoint: @settings.endpoint, api_key: @settings.api_key
      ).call(request)
    end
  end

  # Nonblank key/model, an allowlisted provider, and a well-formed http/https endpoint
  # (host present, no userinfo) are all required before any transport is built.
  def config_valid?
    @settings.api_key.present? && @settings.model.present? &&
      Marine::Llm::ProviderConfig::PROVIDERS.key?(@settings.provider) &&
      valid_endpoint?(@settings.endpoint)
  end

  def valid_endpoint?(endpoint)
    uri = URI.parse(endpoint.to_s)
    %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError
    false
  end

  # Canonicalize into a NEW symbol-keyed hash (never mutate/freeze the caller's request)
  # while rejecting, BEFORE symbolization, any key outside the selected protocol and any
  # duplicate canonical String/Symbol key (symbolize_keys would silently collapse those,
  # letting a smuggled second value win). Arbitrary fields never reach a provider.
  def filter_request(mode, request)
    allowed = mode == 'openrouter_decisions' ? DECISIONS_KEYS : CHAT_KEYS
    canonical_attrs(request, allowed)
  end

  def canonical_attrs(request, allowed)
    return nil unless request.is_a?(Hash)

    attrs = {}
    request.each do |key, value|
      return nil unless key.is_a?(String) || key.is_a?(Symbol)

      canonical = key.to_sym
      return nil unless allowed.include?(canonical)
      return nil if attrs.key?(canonical)

      attrs[canonical] = value
    end
    attrs
  end

  def failure(reason, mode)
    Marine::Decision::TransportResult.failure(reason: reason, api_mode: mode)
  end
end
