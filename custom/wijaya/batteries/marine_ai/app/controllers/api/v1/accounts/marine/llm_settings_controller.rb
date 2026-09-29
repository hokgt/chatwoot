# Admin-configurable Marine LLM provider settings. Marine drives two independent
# models — a Decision Maker (routing & intent) and a Response Generator (persona &
# presentation) — each with its own provider/model/endpoint/API key. Both persist
# through Marine::Llm::SettingsStore onto MARINE_* InstallationConfig keys (never
# CAPTAIN_*); the response generator maps to the legacy runtime keys so saving it
# keeps the unchanged message runner in step. The raw API key is never returned —
# only a masked preview and a presence flag, independently per model.
class Api::V1::Accounts::Marine::LlmSettingsController < Api::V1::Accounts::BaseController
  before_action :current_account
  # The AI Provider (LLM Settings) area is administrator-only. Reading the provider
  # configuration (show) is gated too — it exposes the configured provider/endpoint
  # and a masked key preview — so no non-administrator can read or mutate it.
  before_action :authorize_account_update

  TARGET_PARAM_KEYS = {
    decision_maker: :decision_maker_config,
    response_generator: :response_generator_config
  }.freeze

  CONFIG_FIELDS = %i[provider model api_endpoint api_key].freeze

  # Raised for a client-supplied config that must never reach the store: an
  # unknown provider identifier or a malformed nested block. Rendered as 422.
  class InvalidConfigError < StandardError; end

  def show
    render json: settings_payload
  end

  def update
    # Parse/validate both blocks BEFORE the transaction so an invalid target aborts
    # the request without any partial write; the transaction still guards the pair.
    targets = TARGET_PARAM_KEYS.transform_values { |param_key| config_params(param_key) }

    ActiveRecord::Base.transaction do
      TARGET_PARAM_KEYS.each_key do |target|
        attrs = targets[target]
        Marine::Llm::SettingsStore.for(target).write(attrs) if attrs.present?
      end
    end

    render json: settings_payload
  rescue InvalidConfigError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def test
    target = params[:target].to_s.presence
    return render_invalid_target unless Marine::Llm::SettingsStore.target?(target)

    store = Marine::Llm::SettingsStore.for(target)
    render json: run_connection_test(store, config_params(:config))
  rescue InvalidConfigError => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  private

  # Runs a connection test with the submitted values, falling back to the stored
  # config for that target on any blank field.
  def run_connection_test(store, submitted)
    Marine::Llm::ConnectionTestService.new(
      provider: submitted[:provider].presence || store.provider,
      api_key: submitted[:api_key].presence || store.api_key,
      endpoint: submitted[:endpoint].presence || store.endpoint,
      model: submitted[:model].presence || store.model
    ).call
  end

  def authorize_account_update
    authorize Current.account, :update?
  end

  # Permits a single nested config block and normalizes the public `api_endpoint`
  # field to the internal `endpoint` name expected by the store. A block that is
  # present but not an object (scalar/array) is rejected as malformed rather than
  # blowing up on `permit`, and an unknown provider is rejected outright so no
  # arbitrary provider identifier is ever persisted.
  def config_params(param_key)
    nested = params[param_key]
    return {} if nested.blank?
    raise InvalidConfigError, 'Malformed configuration payload' unless nested.is_a?(ActionController::Parameters)

    attrs = nested.permit(*CONFIG_FIELDS).to_h.symbolize_keys
    attrs[:endpoint] = attrs.delete(:api_endpoint) if attrs.key?(:api_endpoint)
    validate_provider!(attrs[:provider])
    attrs
  end

  # A supplied provider must be one of the registered providers; blank means
  # "leave unchanged" (update) or "use the stored value" (test), which is allowed.
  def validate_provider!(provider)
    return if provider.blank?
    return if Marine::Llm::ProviderConfig::PROVIDERS.key?(provider)

    raise InvalidConfigError, 'Unsupported provider'
  end

  def settings_payload
    {
      decision_maker_config: Marine::Llm::SettingsStore.for(:decision_maker).to_view,
      response_generator_config: Marine::Llm::SettingsStore.for(:response_generator).to_view,
      available_providers: Marine::Llm::ProviderConfig.available_providers
    }
  end

  def render_invalid_target
    render json: { ok: false, error: 'Invalid or missing target' }, status: :unprocessable_entity
  end
end
