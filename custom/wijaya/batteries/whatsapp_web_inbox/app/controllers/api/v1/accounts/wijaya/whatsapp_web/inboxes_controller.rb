# WIJAYA_CUSTOM_START whatsapp_web_inbox
# Account-scoped, admin-only management API for WhatsApp Web (Unofficial) inboxes.
# The browser talks ONLY to these endpoints; Rails alone signs and calls the connector.
# Every response is a sanitized DTO (SafeDto) — the raw QR string, connector/channel
# secrets, hmac token, and full phone/JID never cross this boundary. Member actions are
# scoped through Current.account.inboxes, so IDs from another account resolve to 404.
# Missing/unavailable connector fails closed for control operations (503) and degrades
# gracefully (connector_available:false) for status/QR so the settings page never crashes.
class Api::V1::Accounts::Wijaya::WhatsappWeb::InboxesController < Api::V1::Accounts::BaseController
  Record = Wijaya::Batteries::WhatsappWebInbox::Record
  Config = Wijaya::Batteries::WhatsappWebInbox::Config
  SafeDto = Wijaya::Batteries::WhatsappWebInbox::SafeDto
  Provisioner = Wijaya::Batteries::WhatsappWebInbox::Provisioner
  ConnectorClient = Wijaya::Batteries::WhatsappWebInbox::ConnectorClient
  ProvisionJob = Wijaya::Batteries::WhatsappWebInbox::ProvisionJob

  # Server-side bounds on browser-driven connector calls (per inbox, per operation).
  POLL_COOLDOWN_SECONDS = 1
  CONTROL_COOLDOWN_SECONDS = 3

  before_action :check_admin_authorization?
  before_action :ensure_connector_configured, only: %i[create connect reconnect logout retry]
  before_action :set_record, only: %i[show qr connect reconnect logout retry]

  def show
    return if throttle!('status', POLL_COOLDOWN_SECONDS)

    available = true
    session = begin
      refresh_status!
    rescue ConnectorClient::Error
      available = false
      nil
    end
    render json: SafeDto.inbox(@record.reload, session: session, connector_available: available)
  end

  def create
    return render_error('acknowledgement_required', :unprocessable_entity) unless acknowledged?
    return render_error('name_required', :unprocessable_entity) if create_params[:name].blank?
    return render_error('request_token_required', :unprocessable_entity) if create_params[:request_token].blank?

    record = Provisioner.create!(account: Current.account, name: create_params[:name].strip,
                                 request_token: create_params[:request_token])
    return render_error('request_token_conflict', :unprocessable_entity) if record.nil?

    render json: SafeDto.inbox(record), status: :created
  end

  def qr
    return if throttle!('qr', POLL_COOLDOWN_SECONDS)

    available = true
    result = begin
      @record.connector_session_id.present? ? ConnectorClient.new.qr(@record.connector_session_id) : nil
    rescue ConnectorClient::Error
      available = false
      nil
    end
    render json: SafeDto.qr(@record, result, connector_available: available)
  end

  def connect
    control!(:connect)
  end

  def reconnect
    control!(:reconnect)
  end

  def logout
    control!(:logout)
  end

  def retry
    return if throttle!('retry', CONTROL_COOLDOWN_SECONDS)

    ProvisionJob.perform_later(record_id: @record.id)
    render json: SafeDto.inbox(@record)
  end

  private

  # Run a connector control action against the provisioned session and reflect the
  # returned status. Degrades to connector_available:false on any connector error.
  def control!(action)
    return if throttle!(action.to_s, CONTROL_COOLDOWN_SECONDS)
    return render_error('not_provisioned', :unprocessable_entity) if @record.connector_session_id.blank?

    available = true
    begin
      response = ConnectorClient.new.public_send(action, @record.connector_session_id)
      @record.update!(status: Record.sanitize_status(response['status']))
    rescue ConnectorClient::Error
      available = false
    end
    render json: SafeDto.inbox(@record.reload, connector_available: available)
  end

  def refresh_status!
    return nil if @record.connector_session_id.blank?

    session = ConnectorClient.new.get_session(@record.connector_session_id)
    @record.update!(status: Record.sanitize_status(session['status']))
    session
  end

  def set_record
    inbox = Current.account.inboxes.find(params[:id])
    @record = inbox.wijaya_whatsapp_web_inbox
    render_error('not_found', :not_found) if @record.nil?
  end

  def ensure_connector_configured
    render_error('connector_unavailable', :service_unavailable) unless Config.configured?
  end

  def throttle!(suffix, seconds)
    key = "WIJAYA_WHATSAPP_WEB_RL::#{@record.id}::#{suffix}"
    return false if ::Redis::Alfred.set(key, '1', nx: true, ex: seconds)

    render json: { error: 'rate_limited' }, status: :too_many_requests
    true
  end

  def acknowledged?
    ActiveModel::Type::Boolean.new.cast(create_params[:acknowledged]) == true
  end

  def create_params
    params.permit(:name, :request_token, :acknowledged)
  end

  def render_error(code, status)
    render json: { error: code }, status: status
  end
end
# WIJAYA_CUSTOM_END whatsapp_web_inbox
