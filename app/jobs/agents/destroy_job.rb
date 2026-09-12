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
      # Hand the deleted agent's still-assigned conversations to the battery: it row-locks them
      # FOR UPDATE inside THIS transaction, clears exactly the rows still owned by the agent,
      # records best-effort provenance, and returns the exact cleared ids for the post-commit
      # bridge. If the battery is unavailable or its hook fails, the fail-open dispatcher returns
      # nil; we then preserve native deletion semantics with the original unassignment and dispatch
      # no (guessed) post-commit ids.
      wijaya_unassigned_conversation_ids = Wijaya::Batteries::Core::Hooks.dispatch(
        :deferred_auto_assignment, :unassign_deleted_agent_conversations,
        default: nil, account_id: account.id, user_id: user.id, deletion_key: job_id
      )
      if wijaya_unassigned_conversation_ids.nil?
        unassign_conversations(account, user)
        wijaya_unassigned_conversation_ids = []
      end
      # WIJAYA_CUSTOM_END deferred_auto_assignment
    end
    # WIJAYA_CUSTOM_START deferred_auto_assignment
    # Post-commit: hand the just-cleared conversations to the deferred auto-assignment battery.
    # Fail-open; retry/crash-window semantics are documented in the battery registrar.
    wijaya_bridge_agent_deletion_auto_assignment(account, wijaya_unassigned_conversation_ids)
    # WIJAYA_CUSTOM_END deferred_auto_assignment
  end

  private

  # WIJAYA_CUSTOM_START deferred_auto_assignment
  # Post-commit bridge: hand the exact cleared conversations to the deferred auto-assignment battery
  # for re-assignment. Fail-open; retry/crash-window semantics are documented in the battery
  # registrar. Skipped entirely when the battery cleared nothing or is unavailable.
  def wijaya_bridge_agent_deletion_auto_assignment(account, conversation_ids)
    return if conversation_ids.blank?
    return unless defined?(Wijaya::Batteries::Core::Hooks)

    Wijaya::Batteries::Core::Hooks.dispatch(
      :deferred_auto_assignment, :on_agent_deletion_unassigned,
      default: nil, account_id: account.id, conversation_ids: conversation_ids
    )
  end
  # WIJAYA_CUSTOM_END deferred_auto_assignment

  # Native fail-open fallback (upstream behaviour): clear the deleted agent's conversation
  # assignments when the deferred auto-assignment battery is unavailable or its hook fails.
  def unassign_conversations(account, user)
    # rubocop:disable Rails/SkipsModelValidations
    user.assigned_conversations.where(account: account).in_batches.update_all(assignee_id: nil)
    # rubocop:enable Rails/SkipsModelValidations
  end

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
end
