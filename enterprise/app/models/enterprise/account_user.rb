require Rails.root.join('custom/wijaya/batteries/custom_roles/hooks')

module Enterprise::AccountUser
  # WIJAYA_CUSTOM_START custom_roles_rbac
  def permissions
    Wijaya::Batteries::CustomRoles::Hooks.account_user_permissions(self, super)
  end
  # WIJAYA_CUSTOM_END custom_roles_rbac
end
