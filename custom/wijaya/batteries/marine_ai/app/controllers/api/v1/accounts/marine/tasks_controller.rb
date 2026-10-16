require Rails.root.join('custom/wijaya/batteries/custom_roles/hooks')

# Marine-owned composer AI tasks. It routes to Marine Copilot services and Marine's own LLM foundation. It never
# depends on external premium gates, hub services, pricing plans, or feature flags,
# and returns the same { message:, follow_up_context: } response shape the
# existing composer (useCaptain/useCopilotReply) already expects.
class Api::V1::Accounts::Marine::TasksController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action :check_authorization

  # Conversation-bound tasks (reply_suggestion, summarize, follow_up) resolve and
  # authorize the conversation with the exact same visibility semantics as
  # conversation show BEFORE any Marine service is instantiated. rewrite/translate
  # are context-free: a supplied conversation_display_id is ignored — never
  # resolved, never authorized.
  #
  # Every success response that carries a follow_up_context is signed with a
  # server-issued, tamper-evident provenance token (custom_roles_rbac battery:
  # bound to the issuing account and, for conversation-bound origins, the
  # authorized conversation). The token is compact and opaque — provenance
  # metadata plus a SHA-256 digest of the canonical context, never the raw
  # context/transcript. follow_up verifies it fail-closed BEFORE the service
  # and accepts the client context only after a constant-time digest match.

  def reply_suggestion
    conversation = authorize_conversation!
    return if conversation == :denied

    render_result(
      Marine::Copilot::ReplySuggestionService.new(
        account: Current.account,
        conversation: conversation,
        user: Current.user
      ).perform,
      conversation_display_id: conversation.display_id
    )
  end

  def rewrite
    render_result(
      Marine::Copilot::RewriteService.new(
        account: Current.account,
        content: params[:content],
        operation: params[:operation]
      ).perform
    )
  end

  def summarize
    conversation = authorize_conversation!
    return if conversation == :denied

    render_result(
      Marine::Copilot::SummaryService.new(
        account: Current.account,
        conversation: conversation
      ).perform,
      conversation_display_id: conversation.display_id
    )
  end

  def translate
    render_result(
      Marine::Copilot::TranslateService.new(
        account: Current.account,
        content: params[:content],
        target_language: params[:target_language],
        source_language: params[:source_language]
      ).perform
    )
  end

  def follow_up
    conversation = authorize_conversation!
    return if conversation == :denied

    verified = verify_follow_up_context(conversation)
    return if verified.nil?

    render_result(
      Marine::Copilot::FollowUpService.new(
        account: Current.account,
        follow_up_context: verified,
        user_message: params[:message],
        conversation: conversation
      ).perform,
      conversation_display_id: conversation.display_id
    )
  end

  private

  # Wijaya composer-task conversation authorization (custom_roles_rbac battery):
  # resolves the conversation inside Current.account and enforces conversation-show
  # visibility (404 blank/unknown/cross-account display id, explicit 403 for
  # custom-role agents, Pundit 401 otherwise) before any Marine service is
  # instantiated. Returns the authorized Conversation, or the :denied symbol when
  # the custom-role 403 response was rendered.
  def authorize_conversation!
    Wijaya::Batteries::CustomRoles::Hooks.authorize_composer_conversation!(
      controller: self,
      display_id: params[:conversation_display_id]
    )
  end

  # Wijaya follow-up provenance (custom_roles_rbac battery): verifies the
  # server-issued follow_up_context token against the authorized conversation
  # fail-closed (concise 422) BEFORE the service. The token carries only
  # metadata plus a SHA-256 digest of the canonical context (no raw
  # transcript); the client context is accepted only after a constant-time
  # digest match, so any changed client field is rejected, and legacy unsigned
  # contexts fail closed. Raw params go straight to the battery: malformed
  # (non-object) follow_up_context values fail closed as the same concise 422.
  def verify_follow_up_context(conversation)
    verified = Wijaya::Batteries::CustomRoles::FollowUpProvenance.verify_follow_up_context(
      params[:follow_up_context],
      account_id: Current.account.id,
      conversation_display_id: conversation.display_id
    )
    return verified unless verified.nil?

    render json: { error: Wijaya::Batteries::CustomRoles::FollowUpProvenance::REJECTION_ERROR }, status: :unprocessable_entity
    nil
  end

  def render_result(result, conversation_display_id: nil)
    if result.nil?
      render json: { message: nil }
    elsif result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      response_data = { message: result[:message] }
      if result[:follow_up_context]
        response_data[:follow_up_context] = Wijaya::Batteries::CustomRoles::FollowUpProvenance.attach_token(
          result[:follow_up_context],
          account_id: Current.account.id,
          conversation_display_id: conversation_display_id
        )
      end
      render json: response_data
    end
  end

  def check_authorization
    authorize(:'marine/tasks')
  end
end
