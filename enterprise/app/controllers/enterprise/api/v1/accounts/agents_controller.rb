module Enterprise::Api::V1::Accounts::AgentsController
  def create
    super
    associate_agent_with_custom_role
  end

  def update
    super
    associate_agent_with_custom_role
  end

  private

  def associate_agent_with_custom_role
    # WIJAYA_CUSTOM_START custom_roles_rbac
    return unless params[:agent]&.key?(:custom_role_id) || params.key?(:custom_role_id)

    custom_role_id = params.dig(:agent, :custom_role_id) || params[:custom_role_id]
    @agent.current_account_user.update!(custom_role_id: custom_role_id)
    # WIJAYA_CUSTOM_END custom_roles_rbac
  end
end
