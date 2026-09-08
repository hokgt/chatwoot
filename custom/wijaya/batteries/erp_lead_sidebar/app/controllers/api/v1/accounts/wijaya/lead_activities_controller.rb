# WIJAYA_CUSTOM_START erp_lead_sidebar
# Account-scoped, nested under an existing ERP Lead draft (addressed by the
# conversation display_id). Owns the manual Lead Activity form: runtime option
# fetch + a single guarded insert. It never creates a draft and never touches
# the Lead Details create/update/refresh/sync flow.
class Api::V1::Accounts::Wijaya::LeadActivitiesController < Api::V1::Accounts::BaseController
  before_action :set_conversation
  before_action :authorize_conversation
  before_action :set_draft

  # Runtime Lead Activity Master options + the account-timezone default date +
  # the selectable ERP Users for the manual Person In Charge picker. Fetched only
  # when the Activity view opens and only for a linked draft.
  def options
    return render_unconfigured unless erp_configured?
    return render_lead_required if @draft.nil? || @draft.erp_lead_id.to_s.strip.empty?

    service = ::Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService.new(Current.account)
    names = service.fetch_names
    default_date = service.default_date
    pic = person_in_charge_options
    render json: {
      options: names, default_date: default_date,
      person_in_charge_options: pic[:options], person_in_charge_available: pic[:available]
    }
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError
    # Never surface the raw ERPNext response/exception to the agent.
    render json: { error: 'Lead Activity options are currently unavailable.', options: [] }, status: :bad_gateway
  end

  def create
    return render_unconfigured unless erp_configured?
    return render_lead_required if @draft.nil? || @draft.erp_lead_id.to_s.strip.empty?

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

  # Selectable ERP Users for the manual Person In Charge picker. A directory
  # outage never destroys the (otherwise valid) Lead Activity options: it
  # degrades to an empty, optional list flagged unavailable so the agent can
  # still submit with a blank Person In Charge.
  def person_in_charge_options
    options = ::Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory.fetch_options(Current.account)
    { options: options, available: true }
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError
    { options: [], available: false }
  end

  # Find the existing draft only; a Lead Activity must never create a draft.
  def set_draft
    @draft = ::Wijaya::ErpLeadDraft.find_by(account: Current.account, conversation: @conversation)
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
