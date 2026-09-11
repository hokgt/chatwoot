class Agents::DestroyJob < ApplicationJob
  queue_as :low

  def perform(account, user)
    # WIJAYA_CUSTOM_START deferred_auto_assignment
    wijaya_unassigned_conversation_ids = []
    # WIJAYA_CUSTOM_END deferred_auto_assignment
    ActiveRecord::Base.transaction do
      destroy_notification_setting(account, user)
      remove_user_from_teams(account, user)
      remove_user_from_inboxes(account, user)
      # WIJAYA_CUSTOM_START deferred_auto_assignment
      # Capture the exact conversations this deletion will clear, before the update_all below.
      wijaya_unassigned_conversation_ids = user.assigned_conversations.where(account: account).ids
      # WIJAYA_CUSTOM_END deferred_auto_assignment
      unassign_conversations(account, user)
    end
    # WIJAYA_CUSTOM_START deferred_auto_assignment
    # Post-commit: hand the just-cleared conversations to the deferred auto-assignment battery.
    # Fail-open; retry/crash-window semantics are documented in the battery registrar.
    wijaya_bridge_agent_deletion_auto_assignment(account, wijaya_unassigned_conversation_ids)
    # WIJAYA_CUSTOM_END deferred_auto_assignment
  end

  private

  # WIJAYA_CUSTOM_START deferred_auto_assignment
  def wijaya_bridge_agent_deletion_auto_assignment(account, conversation_ids)
    return if conversation_ids.blank?
    return unless defined?(Wijaya::Batteries::Core::Hooks)

    Wijaya::Batteries::Core::Hooks.dispatch(
      :deferred_auto_assignment, :on_agent_deletion_unassigned,
      default: nil, account_id: account.id, conversation_ids: conversation_ids
    )
  end
  # WIJAYA_CUSTOM_END deferred_auto_assignment

  def remove_user_from_inboxes(account, user)
    inboxes = account.inboxes.all
    inbox_members = user.inbox_members.where(inbox_id: inboxes.pluck(:id))
    inbox_members.destroy_all
  end

  def remove_user_from_teams(account, user)
    teams = account.teams.all
    team_members = user.team_members.where(team_id: teams.pluck(:id))
    team_members.destroy_all
  end

  def destroy_notification_setting(account, user)
    setting = user.notification_settings.find_by(account_id: account.id)
    setting&.destroy!
  end

  def unassign_conversations(account, user)
    # rubocop:disable Rails/SkipsModelValidations
    user.assigned_conversations.where(account: account).in_batches.update_all(assignee_id: nil)
    # rubocop:enable Rails/SkipsModelValidations
  end
end
