# Marine-owned composer AI tasks. It routes to Marine Copilot services and Marine's own LLM foundation. It never
# depends on external premium gates, hub services, pricing plans, or feature flags,
# and returns the same { message:, follow_up_context: } response shape the
# existing composer (useCaptain/useCopilotReply) already expects.
class Api::V1::Accounts::Marine::TasksController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action :check_authorization

  def reply_suggestion
    render_result(
      Marine::Copilot::ReplySuggestionService.new(
        account: Current.account,
        conversation: conversation,
        user: Current.user
      ).perform
    )
  end

  def rewrite
    render_result(
      Marine::Copilot::RewriteService.new(
        account: Current.account,
        content: params[:content],
        operation: params[:operation],
        conversation: conversation
      ).perform
    )
  end

  def summarize
    render_result(
      Marine::Copilot::SummaryService.new(
        account: Current.account,
        conversation: conversation
      ).perform
    )
  end

  def translate
    render_result(
      Marine::Copilot::TranslateService.new(
        account: Current.account,
        content: params[:content],
        target_language: params[:target_language],
        source_language: params[:source_language],
        conversation: conversation
      ).perform
    )
  end

  def follow_up
    render_result(
      Marine::Copilot::FollowUpService.new(
        account: Current.account,
        follow_up_context: params[:follow_up_context]&.to_unsafe_h,
        user_message: params[:message],
        conversation: conversation
      ).perform
    )
  end

  private

  def conversation
    return if params[:conversation_display_id].blank?

    @conversation ||= Current.account.conversations.find_by(display_id: params[:conversation_display_id])
  end

  def render_result(result)
    if result.nil?
      render json: { message: nil }
    elsif result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      response_data = { message: result[:message] }
      response_data[:follow_up_context] = result[:follow_up_context] if result[:follow_up_context]
      render json: response_data
    end
  end

  def check_authorization
    authorize(:'marine/tasks')
  end
end
