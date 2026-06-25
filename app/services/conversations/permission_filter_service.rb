require Rails.root.join('custom/wijaya/batteries/custom_roles/hooks')

class Conversations::PermissionFilterService
  attr_reader :conversations, :user, :account

  def initialize(conversations, user, account)
    @conversations = conversations
    @user = user
    @account = account
  end

  # WIJAYA_CUSTOM_START custom_roles_rbac
  def self.allowed?(conversation, user, account)
    Wijaya::Batteries::CustomRoles::Hooks.conversation_allowed?(conversation, user, account)
  end
  # WIJAYA_CUSTOM_END custom_roles_rbac

  def perform
    return conversations if user_role == 'administrator'

    accessible_conversations
  end

  private

  def accessible_conversations
    conversations.where(inbox: user.inboxes.where(account_id: account.id))
  end

  def account_user
    AccountUser.find_by(account_id: account.id, user_id: user.id)
  end

  def user_role
    account_user&.role
  end
end

Conversations::PermissionFilterService.prepend_mod_with('Conversations::PermissionFilterService')
