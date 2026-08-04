# Shared plumbing for Marine copilot natural-language search services. Every
# subclass is account + user scoped and reuses Chatwoot's own RBAC surfaces
# (Conversations::PermissionFilterService, account membership) so results never
# leak across accounts and respect per-user conversation visibility.
#
# Fully Marine-owned: no Captain runtime dependencies, no premium gates, no hub
# checks. Services return plain JSON-safe hashes/arrays and never raise on empty
# input.
class Marine::Copilot::SearchBaseService
  MAX_RESULTS = 20

  def initialize(account:, user: nil)
    @account = account
    @user = user
  end

  private

  attr_reader :account, :user

  # Conversations the current user is allowed to see within this account. Falls
  # back to the account's conversations when no user is supplied (server-side
  # callers), and applies Chatwoot's PermissionFilterService for real users so
  # non-admins only see conversations in their inboxes.
  def permissible_conversations
    scope = account.conversations
    return scope if user.blank?

    Conversations::PermissionFilterService.new(scope, user, account).perform
  end

  # Contacts are account-scoped in Chatwoot core. Only expose them to users who
  # have contact access (admins/agents or a custom role granting contact_manage).
  def contacts_accessible?
    return true if user.blank?
    return false if account_user.blank?
    return account_user.custom_role.permissions.include?('contact_manage') if account_user.custom_role.present?

    account_user.administrator? || account_user.agent?
  end

  def account_user
    @account_user ||= AccountUser.find_by(account_id: account.id, user_id: user&.id)
  end

  def conversation_citation(conversation)
    {
      type: 'conversation',
      id: conversation.display_id,
      title: "Conversation ##{conversation.display_id}",
      status: conversation.status,
      url: "/app/accounts/#{account.id}/conversations/#{conversation.display_id}"
    }
  end

  def contact_citation(contact)
    {
      type: 'contact',
      id: contact.id,
      name: contact.name.presence || contact.email.presence || "Contact ##{contact.id}",
      email: contact.email,
      url: "/app/accounts/#{account.id}/contacts/#{contact.id}"
    }
  end
end
