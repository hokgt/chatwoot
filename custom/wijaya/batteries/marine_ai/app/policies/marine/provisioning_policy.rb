# Provisioning state and actions are INSTALLATION-WIDE (one dedicated Marine
# database per Chatwoot install), so a plain account administrator is not enough.
# Every endpoint requires BOTH:
#   * the current account membership is an administrator, AND
#   * the current user is a Chatwoot installation SuperAdmin.
# Backend authorization is the real gate and must never trust the UI. A regular
# account administrator (or agent) in any account is denied.
class Marine::ProvisioningPolicy < ApplicationPolicy
  def provision?
    account_administrator? && super_admin?
  end

  private

  def account_administrator?
    @account_user&.administrator? || false
  end

  # SuperAdmin is STI on the users table (type = 'SuperAdmin'). Check the class
  # identity robustly so a subclass-reloading nuance can never downgrade the gate:
  # accept a genuine SuperAdmin instance OR an STI record whose type column says so.
  def super_admin?
    return false if @user.nil?

    @user.is_a?(SuperAdmin) || @user.try(:type).to_s == 'SuperAdmin'
  end
end
