require Rails.root.join('custom/wijaya/batteries/custom_roles/hooks')

# == Schema Information
#
# Table name: account_users
#
#  id                       :bigint           not null, primary key
#  active_at                :datetime
#  auto_offline             :boolean          default(TRUE), not null
#  availability             :integer          default("online"), not null
#  role                     :integer          default("agent")
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  account_id               :bigint
#  agent_capacity_policy_id :bigint
#  custom_role_id           :bigint
#  inviter_id               :bigint
#  user_id                  :bigint
#
# Indexes
#
#  index_account_users_on_account_id                (account_id)
#  index_account_users_on_agent_capacity_policy_id  (agent_capacity_policy_id)
#  index_account_users_on_custom_role_id            (custom_role_id)
#  index_account_users_on_user_id                   (user_id)
#  uniq_user_id_per_account_id                      (account_id,user_id) UNIQUE
#

class AccountUser < ApplicationRecord
  include AvailabilityStatusable

  belongs_to :account
  belongs_to :user
  belongs_to :inviter, class_name: 'User', optional: true

  enum role: { agent: 0, administrator: 1 }
  enum availability: { online: 0, offline: 1, busy: 2 }

  accepts_nested_attributes_for :account

  after_create_commit :notify_creation, :create_notification_setting
  after_destroy :notify_deletion, :remove_user_from_account
  after_save :update_presence_in_redis, if: :saved_change_to_availability?
  # WIJAYA_CUSTOM_START deferred_auto_assignment
  # An actual availability transition to online (from offline/busy) can make this agent the
  # first eligible one for conversations that were waiting on a deferred marker. Run after
  # commit so a rolled-back change never enqueues work; the battery filters the exact
  # transition and coalesces per inbox. Fail-open via the core dispatcher.
  after_update_commit :wijaya_process_deferred_on_availability, if: :saved_change_to_availability?
  # WIJAYA_CUSTOM_END deferred_auto_assignment

  validates :user_id, uniqueness: { scope: :account_id }

  def create_notification_setting
    setting = user.notification_settings.new(account_id: account.id)
    setting.selected_email_flags = [:email_conversation_assignment]
    setting.selected_push_flags = [:push_conversation_assignment]
    setting.save!
  end

  def remove_user_from_account
    ::Agents::DestroyJob.perform_later(account, user)
  end

  def permissions
    administrator? ? ['administrator'] : ['agent']
  end

  # WIJAYA_CUSTOM_START custom_roles_rbac
  def can_manage_all_conversations?
    Wijaya::Batteries::CustomRoles::Hooks.can_manage_all_conversations?(self)
  end
  # WIJAYA_CUSTOM_END custom_roles_rbac

  def push_event_data
    {
      id: id,
      availability: availability,
      role: role,
      user_id: user_id
    }
  end

  private

  def notify_creation
    Rails.configuration.dispatcher.dispatch(AGENT_ADDED, Time.zone.now, account: account)
  end

  def notify_deletion
    Rails.configuration.dispatcher.dispatch(AGENT_REMOVED, Time.zone.now, account: account)
  end

  def update_presence_in_redis
    OnlineStatusTracker.set_status(account.id, user.id, availability)
  end

  # WIJAYA_CUSTOM_START deferred_auto_assignment
  def wijaya_process_deferred_on_availability
    return unless defined?(Wijaya::Batteries::Core::Hooks)

    Wijaya::Batteries::Core::Hooks.dispatch(
      :deferred_auto_assignment, :on_agent_available,
      default: nil, account_id: account_id, user_id: user_id,
      previous_availability: saved_change_to_availability&.first, current_availability: availability
    )
  end
  # WIJAYA_CUSTOM_END deferred_auto_assignment
end

AccountUser.prepend_mod_with('AccountUser')
AccountUser.include_mod_with('Audit::AccountUser')
AccountUser.include_mod_with('Concerns::AccountUser')
