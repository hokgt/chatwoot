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
    Wijaya::Batteries::CustomRoles::Hooks.associate_agent_with_custom_role(@agent, params)
    # WIJAYA_CUSTOM_END custom_roles_rbac
  end
end
