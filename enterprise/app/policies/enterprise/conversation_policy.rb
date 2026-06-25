require Rails.root.join('custom/wijaya/batteries/custom_roles/hooks')

module Enterprise::ConversationPolicy
  def show?
    return true if administrator? || agent_bot?
    return super unless custom_role_permissions?

    # WIJAYA_CUSTOM_START custom_roles_rbac
    Wijaya::Batteries::CustomRoles::Hooks.conversation_visible?(record, user, account)
    # WIJAYA_CUSTOM_END custom_roles_rbac
  end

  private

  def custom_role_permissions?
    # WIJAYA_CUSTOM_START custom_roles_rbac
    Wijaya::Batteries::CustomRoles::Hooks.custom_role_agent?(account_user)
    # WIJAYA_CUSTOM_END custom_roles_rbac
  end
end
