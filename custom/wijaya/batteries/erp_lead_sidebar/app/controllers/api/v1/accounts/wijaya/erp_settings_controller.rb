# WIJAYA_CUSTOM_START erp_lead_sidebar
# Account-scoped, admin-only ERPNext connection settings for the ERP Lead Sidebar.
# Administrators set the ERPNext host, API key, and secret here; agents are denied
# (check_admin_authorization?). The raw key/secret are never returned — only
# presence + source (account/env) metadata. Blank credential inputs on update
# preserve the stored values.
class Api::V1::Accounts::Wijaya::ErpSettingsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?

  def show
    render json: serialize
  end

  def update
    setting = account_setting
    # compact_blank preserves stored credentials when password inputs are blank.
    setting.assign_attributes(settings_params.to_h.compact_blank)
    setting.save!

    render json: serialize
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
  end

  # Runs a minimal authenticated ERPNext request. Uses the submitted values when
  # present, otherwise the currently-resolved (saved or ENV) values, so an admin
  # can verify the stored connection without re-entering the secret.
  def test
    result = ::Wijaya::Batteries::ErpLeadSidebar::ConnectionTestService.new(
      host: settings_params[:host].presence || erp_config.erp_base_url(Current.account),
      api_key: settings_params[:api_key].presence || erp_config.erp_api_key(Current.account),
      api_secret: settings_params[:api_secret].presence || erp_config.erp_api_secret(Current.account)
    ).call

    render json: result
  end

  private

  def erp_config
    ::Wijaya::Batteries::ErpLeadSidebar::Config
  end

  def account_setting
    setting = ::Wijaya::ErpSetting.find_or_initialize_by(account_id: Current.account.id)
    return setting if setting.persisted?

    # First save migrates inherited ENV credentials into encrypted account
    # storage, preventing a host-only save from shadowing a working fallback.
    setting.api_key = ENV.fetch('WIJAYA_ERP_API_KEY', nil).presence
    setting.api_secret = ENV.fetch('WIJAYA_ERP_API_SECRET', nil).presence
    setting
  end

  def saved_setting
    ::Wijaya::ErpSetting.find_by(account_id: Current.account.id)
  end

  def settings_params
    params.permit(erp_setting: [:host, :api_key, :api_secret]).fetch(:erp_setting, {})
  end

  def serialize
    setting = saved_setting
    {
      host: erp_config.erp_base_url(Current.account),
      host_source: source_for(setting, setting&.host, ENV.fetch('WIJAYA_ERP_BASE_URL', nil)),
      api_key_present: erp_config.erp_api_key(Current.account).present?,
      api_key_source: source_for(setting, setting&.api_key, ENV.fetch('WIJAYA_ERP_API_KEY', nil)),
      api_secret_present: erp_config.erp_api_secret(Current.account).present?,
      api_secret_source: source_for(setting, setting&.api_secret, ENV.fetch('WIJAYA_ERP_API_SECRET', nil)),
      configured: erp_config.erp_configured?(Current.account)
    }
  end

  # Mirrors Config's row-authoritative resolution so the UI labels match what the
  # backend actually uses: when a saved row exists it is authoritative ('account'
  # when the field is set on it, else nil); ENV is only a source when there is no
  # saved row. Never exposes the value itself.
  def source_for(setting, account_value, env_value)
    if setting
      account_value.present? ? 'account' : nil
    else
      env_value.present? ? 'env' : nil
    end
  end
end
# WIJAYA_CUSTOM_END erp_lead_sidebar
