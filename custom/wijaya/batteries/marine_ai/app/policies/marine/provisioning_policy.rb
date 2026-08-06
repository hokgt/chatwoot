# Provisioning state and actions are INSTALLATION-WIDE (one dedicated Marine
# database per Chatwoot install), but management is gated to an administrator of
# the current account. Backend authorization is the real gate and must never
# trust the UI. An agent (or a user with no administrator membership in the
# current account) is denied.
class Marine::ProvisioningPolicy < ApplicationPolicy
  def provision?
    account_administrator?
  end

  private

  def account_administrator?
    @account_user&.administrator? || false
  end
end
