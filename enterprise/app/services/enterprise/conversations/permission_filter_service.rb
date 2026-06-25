require Rails.root.join('custom/wijaya/batteries/custom_roles/hooks')

module Enterprise::Conversations::PermissionFilterService
  def perform
    return filter_by_permissions(permissions) if user_has_custom_role?

    super
  end

  private

  def user_has_custom_role?
    user_role == 'agent' && account_user&.custom_role_id.present?
  end

  def permissions
    account_user&.permissions || []
  end

  # WIJAYA_CUSTOM_START custom_roles_rbac
  def filter_by_permissions(permissions)
    Wijaya::Batteries::CustomRoles::Hooks.filter_by_permissions(
      accessible_conversations: accessible_conversations,
      permissions: permissions,
      user: user
    )
  end
  # WIJAYA_CUSTOM_END custom_roles_rbac
end
