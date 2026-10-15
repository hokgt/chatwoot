class Api::V1::Accounts::Captain::TasksController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  # WIJAYA_CUSTOM_START custom_roles_rbac
  # Conversation-bound Captain tasks (summarize, reply_suggestion, label_suggestion,
  # follow_up — and rewrite when a conversation_display_id is supplied, because the
  # upstream 'improve' rewrite reads the conversation) must enforce the same
  # conversation visibility as conversation show BEFORE any Captain service is
  # instantiated. rewrite without a conversation_display_id stays context-free.
  # All authorization logic lives in the custom_roles_rbac battery.
  require Rails.root.join('custom/wijaya/batteries/custom_roles/hooks')
  before_action :authorize_conversation_for_ai_task
  # WIJAYA_CUSTOM_END custom_roles_rbac

  def rewrite
    result = Captain::RewriteService.new(
      account: Current.account,
      content: params[:content],
      operation: params[:operation],
      conversation_display_id: params[:conversation_display_id]
    ).perform

    render_result(result)
  end

  def summarize
    result = Captain::SummaryService.new(
      account: Current.account,
      conversation_display_id: params[:conversation_display_id]
    ).perform

    render_result(result)
  end

  def reply_suggestion
    result = Captain::ReplySuggestionService.new(
      account: Current.account,
      conversation_display_id: params[:conversation_display_id],
      user: Current.user
    ).perform

    render_result(result)
  end

  def label_suggestion
    result = Captain::LabelSuggestionService.new(
      account: Current.account,
      conversation_display_id: params[:conversation_display_id]
    ).perform

    render_result(result)
  end

  def follow_up
    # WIJAYA_CUSTOM_START custom_roles_rbac
    # The before_action already authorized the supplied conversation. The
    # follow_up_context token is verified fail-closed (422) BEFORE the service:
    # missing/invalid/tampered tokens, tokens from another account, or a
    # conversation-bound token replayed against a different conversation are
    # rejected. The compact token signs only provenance metadata plus a SHA-256
    # digest of the canonical context (never the raw transcript); the client
    # context is accepted only after a constant-time digest match, so any
    # changed client field fails closed as 422 before the service.
    verified_context = Wijaya::Batteries::CustomRoles::FollowUpProvenance.verify_follow_up_context(
      params[:follow_up_context],
      account_id: Current.account.id,
      conversation_display_id: @wijaya_authorized_conversation.display_id
    )
    if verified_context.nil?
      render json: { error: Wijaya::Batteries::CustomRoles::FollowUpProvenance::REJECTION_ERROR }, status: :unprocessable_content
      return
    end

    result = Captain::FollowUpService.new(
      account: Current.account,
      follow_up_context: verified_context,
      user_message: params[:message],
      conversation_display_id: params[:conversation_display_id]
    ).perform

    render_result(result)
    # WIJAYA_CUSTOM_END custom_roles_rbac
  end

  private

  # WIJAYA_CUSTOM_START custom_roles_rbac
  # Wijaya composer-task conversation authorization: 404 for a blank/unknown/
  # cross-account display id (required actions), explicit 403 for custom-role
  # agents, Pundit ConversationPolicy#show? (401) for everyone else — rendered or
  # raised before any Captain service is instantiated.
  def authorize_conversation_for_ai_task
    @wijaya_authorized_conversation = Wijaya::Batteries::CustomRoles::Hooks.authorize_composer_conversation!(
      controller: self,
      display_id: params[:conversation_display_id],
      required: action_name != 'rewrite'
    )
  end
  # WIJAYA_CUSTOM_END custom_roles_rbac

  def render_result(result)
    if result.nil?
      render json: { message: nil }
    elsif result[:error]
      render json: { error: result[:error] }, status: :unprocessable_content
    else
      response_data = { message: result[:message] }
      # WIJAYA_CUSTOM_START custom_roles_rbac
      # Server-issued tamper-evident provenance for the follow-up context: bound to
      # the issuing account and, when a conversation_display_id was supplied and
      # authorized, to that conversation. rewrite without one stays context-free.
      # The token is compact (metadata + SHA-256 digest, never raw context) and
      # binds the authorized canonical display id (@wijaya_authorized_conversation),
      # never raw params — nil only for genuinely context-free rewrite.
      if result[:follow_up_context]
        response_data[:follow_up_context] = Wijaya::Batteries::CustomRoles::FollowUpProvenance.attach_token(
          result[:follow_up_context],
          account_id: Current.account.id,
          conversation_display_id: @wijaya_authorized_conversation&.display_id
        )
      end
      # WIJAYA_CUSTOM_END custom_roles_rbac
      render json: response_data
    end
  end

  def check_authorization
    authorize(:'captain/tasks')
  end
end

Api::V1::Accounts::Captain::TasksController.prepend_mod_with('Api::V1::Accounts::Captain::TasksController')
