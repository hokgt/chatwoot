require Rails.root.join('custom/wijaya/batteries/custom_roles/hooks')

class Api::V1::Accounts::Conversations::BaseController < Api::V1::Accounts::BaseController
  before_action :conversation

  private

  def conversation
    @conversation ||= Current.account.conversations.find_by!(display_id: params[:conversation_id])
    render_conversation_forbidden unless policy(@conversation).show?
  end

  def render_conversation_forbidden
    # WIJAYA_CUSTOM_START custom_roles_rbac
    render json: Wijaya::Batteries::CustomRoles::Hooks.conversation_forbidden_response, status: :forbidden
    # WIJAYA_CUSTOM_END custom_roles_rbac
  end
end
