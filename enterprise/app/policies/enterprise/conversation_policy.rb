module Enterprise::ConversationPolicy
  def show?
    return true if administrator? || agent_bot?
    return super unless custom_role_permissions?

    Conversations::PermissionFilterService.allowed?(record, user, account)
  end

  private

  def custom_role_permissions?
    account_user&.custom_role_id.present?
  end
end
