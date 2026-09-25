# WIJAYA_CUSTOM_START erp_lead_sidebar
# Account-scoped, nested under an existing ERP Lead draft (addressed by the
# conversation display_id). Owns the manual Lead Activity form: runtime option
# fetch + a single guarded insert. It never creates a draft and never touches
# the Lead Details create/update/refresh/sync flow.
class Api::V1::Accounts::Wijaya::LeadActivitiesController < Api::V1::Accounts::BaseController
  before_action :set_conversation
  before_action :authorize_conversation
  before_action :set_draft

  # Lightweight Activity form metadata: the account-timezone default date only.
  # Deliberately issues NO ERP request (it is a pure Time.zone computation), so it
  # is safe to call on Activity-form mount without any ERP round-trip. Still gated
  # on configuration + a linked ERP Lead, exactly like the option endpoints.
  def meta
    return render_unconfigured unless erp_configured?
    return render_lead_required if lead_missing?

    default_date = ::Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService.new(Current.account).default_date
    render json: { default_date: default_date }
  end

  # Runtime Lead Activity Master options. Fetched lazily, only when the Activity
  # Type / Follow Up Activity dropdown opens, and only for a configured, linked
  # draft. Calls ONLY the Lead Activity Master source (never the User directory).
  # A malformed upstream body is a bad gateway, never a misleading empty list.
  def activity_options
    return render_unconfigured unless erp_configured?
    return render_lead_required if lead_missing?

    names = ::Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService.new(Current.account).fetch_activity_names
    render json: { options: names }
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError => e
    # Never surface the raw ERPNext response/exception to the agent.
    log_dependency_failure('lead_activity_master', e)
    render json: { error: 'Lead Activity options are currently unavailable.', options: [] }, status: :bad_gateway
  end

  # Selectable ERP Users for the manual Person In Charge picker. Fetched lazily,
  # only when the PIC dropdown opens. Calls ONLY the User directory (never the
  # Lead Activity Master source). A directory outage is a sanitized bad gateway so
  # the client can offer Retry; a blank Person In Charge is always submittable.
  def person_in_charge_options
    return render_unconfigured unless erp_configured?
    return render_lead_required if lead_missing?

    options = ::Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory.fetch_options(Current.account)
    render json: { options: options }
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError => e
    log_dependency_failure('erp_user_directory', e)
    render json: { error: 'The ERP user list is currently unavailable.', options: [] }, status: :bad_gateway
  end

  def create
    return render_unconfigured unless erp_configured?
    return render_lead_required if lead_missing?

    result = ::Wijaya::Batteries::ErpLeadSidebar::LeadActivityService.new(
      draft: @draft, agent: Current.user, params: activity_params
    ).perform

    render json: result.body, status: result.http_status
  end

  private

  def set_conversation
    # erp_lead_drafts are addressed by conversation display_id, so the nested
    # parent id (erp_lead_draft_id) carries that display_id.
    @conversation = Current.account.conversations.find_by!(display_id: params[:erp_lead_draft_id])
  end

  # Gate both endpoints on the standard Chatwoot conversation policy: an
  # administrator or an agent with inbox/team access is allowed; an ordinary
  # agent without access to this conversation is denied (Pundit raises ->
  # sanitized 401). This closes the gap where set_conversation resolved any
  # account conversation without an authorization check.
  def authorize_conversation
    authorize @conversation, :show?
  end

  # Find the existing draft only; a Lead Activity must never create a draft.
  def set_draft
    @draft = ::Wijaya::ErpLeadDraft.find_by(account: Current.account, conversation: @conversation)
  end

  # A draft with a linked ERP Lead is required for every endpoint (a Lead Activity
  # is always recorded against an existing Lead); no draft is ever created here.
  def lead_missing?
    @draft.nil? || @draft.erp_lead_id.to_s.strip.empty?
  end

  def erp_configured?
    ::Wijaya::Batteries::ErpLeadSidebar::Config.erp_configured?(Current.account)
  end

  def render_unconfigured
    render json: { configured: false, error: 'ERP connection is not configured.' }, status: :unprocessable_entity
  end

  def render_lead_required
    render json: { error: 'Create or link an ERP Lead before adding an activity.' }, status: :unprocessable_entity
  end

  # Emit one structured, sanitized diagnostic when a Lead Activity dependency
  # fetch fails as a 502. It identifies the specific dependency (`source`) and a
  # safe reason category derived ONLY from our own typed error classes — never the
  # upstream body, exception message, URL, or credentials. Best-effort: a logging
  # failure must never affect the sanitized response. The API response is unchanged.
  def log_dependency_failure(source, error)
    Rails.logger.error(
      {
        event: 'wijaya.erp_lead_sidebar.lead_activity_dependency_failure',
        account_id: Current.account&.id,
        conversation_id: @conversation&.id,
        conversation_display_id: @conversation&.display_id,
        source: source,
        reason: sync_error_reason(error),
        upstream_status: upstream_status_for(error),
        exception_class: error.class.name
      }.compact
    )
  rescue StandardError
    nil
  end

  # Map a rescued SyncError to a safe, allowlisted reason category using only the
  # typed error class (order matters: TimeoutError is a subclass of Error).
  def sync_error_reason(error)
    case error
    when ::Wijaya::Batteries::ErpLeadSidebar::SafeHttp::TimeoutError then :timeout
    when ::Wijaya::Batteries::ErpLeadSidebar::SafeHttp::Error then :transport_error
    when ::Wijaya::Batteries::ErpLeadSidebar::MalformedResponseError then :malformed_response
    when ::Wijaya::Batteries::ErpLeadSidebar::UpstreamHttpError then :upstream_http_error
    else :sync_error
    end
  end

  # The upstream HTTP status code, present only for a non-2xx upstream response.
  def upstream_status_for(error)
    error.status if error.is_a?(::Wijaya::Batteries::ErpLeadSidebar::UpstreamHttpError)
  end

  # Strong params: the structural keys (doctype/parenttype/parent/parentfield)
  # are intentionally excluded so the browser can never set or override them
  # (`parent` is derived server-side from the draft's erp_lead_id). person_in_charge
  # is the agent's manual choice and is permitted here, but it stays untrusted:
  # the service exact-revalidates any nonblank value against the live ERP User
  # directory before it can reach frappe.client.insert.
  def activity_params
    params.permit(
      :submission_id, :date, :lead_activity, :follow_up,
      :follow_up_date, :follow_up_activity, :person_in_charge, :remark
    ).to_h
  end
end
# WIJAYA_CUSTOM_END erp_lead_sidebar
