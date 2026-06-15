class Api::V1::Accounts::Conversations::BaseController < Api::V1::Accounts::BaseController
  before_action :conversation

  private

  def conversation
    @conversation ||= Current.account.conversations.find_by!(display_id: params[:conversation_id])
    render_conversation_forbidden unless policy(@conversation).show?
  end

  def render_conversation_forbidden
    render json: { error: 'You are not authorized to access this conversation' }, status: :forbidden
  end
end
