# WIJAYA_CUSTOM_START erp_lead_sidebar
# Account-scoped, nested under an existing ERP Lead draft (addressed by the
# conversation display_id). Owns the manual Lead Activity form: runtime option
# fetch + a single guarded insert. It never creates a draft and never touches
# the Lead Details create/update/refresh/sync flow.
class Api::V1::Accounts::Wijaya::LeadActivitiesController < Api::V1::Accounts::BaseController
  before_action :set_conversation
  before_action :set_draft

  # Runtime Lead Activity Master options + the account-timezone default date.
  # Fetched only when the Activity view opens and only for a linked draft.
  def options
    return render_unconfigured unless erp_configured?
    return render_lead_required if @draft.nil? || @draft.erp_lead_id.to_s.strip.empty?

    service = ::Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService.new(Current.account)
    render json: { options: service.fetch_names, default_date: service.default_date }
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
  # is likewise excluded — it is derived server-side from the conversation assignee,
  # never trusted from the browser.
  def activity_params
    params.permit(
      :submission_id, :date, :lead_activity, :follow_up,
      :follow_up_date, :follow_up_activity, :remark
    ).to_h
  end
end
# WIJAYA_CUSTOM_END erp_lead_sidebar
