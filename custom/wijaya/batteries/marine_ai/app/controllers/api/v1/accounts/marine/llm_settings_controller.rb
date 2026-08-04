# Admin-configurable Marine LLM provider settings. Reads and writes the MARINE_*
# InstallationConfig keys (never CAPTAIN_*) so administrators can pick a provider,
# model, endpoint, and API key from the dashboard instead of running Rails scripts.
# The raw API key is never returned — only a masked preview and a presence flag.
class Api::V1::Accounts::Marine::LlmSettingsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action :authorize_account_update, only: [:update, :test]

  def show
    render json: current_settings
  end

  def update # rubocop:disable Metrics/AbcSize
    persist('MARINE_LLM_PROVIDER', settings_params[:provider]) if settings_params[:provider].present?
    persist('MARINE_OPEN_AI_MODEL', settings_params[:model]) if settings_params.key?(:model)
    persist('MARINE_OPEN_AI_ENDPOINT', settings_params[:endpoint]) if settings_params.key?(:endpoint)
    persist('MARINE_EMBEDDING_MODEL', settings_params[:embedding_model]) if settings_params.key?(:embedding_model)
    persist('MARINE_OPEN_AI_API_KEY', settings_params[:api_key]) if settings_params[:api_key].present?

    render json: current_settings
  end

  def test
    result = Marine::Llm::ConnectionTestService.new(
      provider: settings_params[:provider].presence || Marine::Llm::Config.provider,
      api_key: settings_params[:api_key].presence || Marine::Llm::Config.api_key,
      endpoint: settings_params[:endpoint].presence || Marine::Llm::Config.endpoint,
      model: settings_params[:model].presence || Marine::Llm::Config.model
    ).call

    render json: result
  end

  private

  def authorize_account_update
    authorize Current.account, :update?
  end

  def settings_params
    params.permit(:provider, :model, :endpoint, :api_key, :embedding_model)
  end

  def persist(name, value)
    config = InstallationConfig.where(name: name).first_or_initialize
    config.value = value
    config.locked = false
    config.save!
  end

  def current_settings
    provider = Marine::Llm::Config.provider
    {
      provider: provider,
      provider_label: Marine::Llm::ProviderConfig.provider_info(provider)[:label],
      model: Marine::Llm::Config.model,
      endpoint: Marine::Llm::Config.endpoint,
      api_key_masked: mask_api_key(Marine::Llm::Config.api_key),
      api_key_present: Marine::Llm::Config.api_key.present?,
      embedding_model: Marine::Llm::Config.installation_value('MARINE_EMBEDDING_MODEL'),
      supports_embeddings: Marine::Llm::ProviderConfig.supports_embeddings?(provider),
      available_providers: Marine::Llm::ProviderConfig.available_providers,
      configured: Marine::Llm::Config.configured?
    }
  end

  def mask_api_key(key)
    return nil if key.blank?
    return '••••' if key.length <= 10

    "#{key[0, 6]}...#{key[-4, 4]}"
  end
end
