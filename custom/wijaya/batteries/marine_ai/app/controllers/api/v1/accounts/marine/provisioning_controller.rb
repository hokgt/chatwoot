# Thin controller for installation-level Marine PostgreSQL provisioning. It holds
# NO SQL and NO business logic — every action delegates to a battery service and
# renders sanitized results. Every endpoint independently requires an account
# administrator (see Marine::ProvisioningPolicy); the frontend gating is not
# trusted. GET actions never mutate state.
class Api::V1::Accounts::Marine::ProvisioningController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action :authorize_admin!
  # Applied to EVERY response — status, credentials, privilege matrix, and sanitized
  # errors alike — so no provisioning response is ever cached by the browser or an
  # intermediary. Set in a before_action so it also covers rescue_from renders.
  before_action :no_store!

  rescue_from Marine::Provisioning::Errors::SanitizedError, with: :render_sanitized_error

  # GET — returns durable NON-SECRET status only. Performs no PostgreSQL action.
  def show
    render json: status_payload
  end

  # POST — creates the dedicated DB + roles exactly once. Returns non-secret
  # connection details for the one-time credential popup (never the password).
  def create
    details = Marine::Provisioning::ProvisionService.new(
      database_name: provisioning_params[:database_name],
      login_username: provisioning_params[:login_username],
      password: provisioning_params[:password],
      actor_id: Current.user&.id
    ).call

    render json: { status: status_payload, credentials: details }, status: :created
  end

  # POST — downgrade the login to a DML-only writer.
  def downgrade
    Marine::Provisioning::PrivilegeService.new(actor_id: Current.user&.id).downgrade_to_writer!
    render json: status_payload
  end

  # POST — reassign owned objects, revoke everything, and set the role NOLOGIN.
  def revoke_all
    Marine::Provisioning::PrivilegeService.new(actor_id: Current.user&.id).revoke_all!
    render json: status_payload
  end

  # GET — read-only privilege matrix from the catalogs (explicit button).
  def privileges
    render json: Marine::Provisioning::CatalogService.new(actor_id: Current.user&.id).call
  end

  private

  def authorize_admin!
    authorize Current.account, :provision?, policy_class: Marine::ProvisioningPolicy
  end

  # Sensitive lifecycle responses (fresh credentials, privilege matrix, state
  # changes) must never be cached by the browser or any intermediary.
  def no_store!
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
  end

  def provisioning_params
    params.require(:provisioning).permit(:database_name, :login_username, :password)
  end

  def status_payload
    Marine::Provisioning::StateStore.current.merge(
      'provisioning_configured' => Marine::Provisioning::Config.configured?
    )
  end

  def render_sanitized_error(error)
    render json: { error: error.message, i18n_key: error.i18n_key }, status: error_status(error)
  end

  def error_status(error)
    case error
    when Marine::Provisioning::Errors::CredentialUnavailableError then :service_unavailable
    when Marine::Provisioning::Errors::LockUnavailableError then :conflict
    when Marine::Provisioning::Errors::AlreadyProvisionedError then :conflict
    else :unprocessable_entity
    end
  end
end
