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
      # Row-lock (FOR UPDATE) the conversations still assigned to this user, clear ONLY those still
      # owned by the user while the lock is held, and record best-effort provenance for EXACTLY the
      # rows we cleared. A concurrent manual reassignment is serialized either fully before our lock
      # (excluded from every step) or fully after our commit (it wins), so this deletion can never
      # clear — nor write a tombstone for — a conversation it did not actually unassign. Only the
      # exact cleared ids are dispatched post-commit. Provenance capture is best-effort/fail-open
      # (see ProvenanceRecorder): a recorder failure leaves that tombstone absent while the deletion
      # still commits — it is never guaranteed atomic completeness.
      wijaya_unassigned_conversation_ids = wijaya_unassign_deleted_agent_conversations(account, user)
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
  # Locks the deleted agent's still-assigned conversations FOR UPDATE, clears exactly the rows still
  # owned by this user (a conditional compare-and-set that also defends against any write the lock
  # could not have serialized), records best-effort provenance for precisely the cleared rows, and
  # returns those ids. Returns [] when the agent owns nothing (a retried deletion is a safe no-op).
  def wijaya_unassign_deleted_agent_conversations(account, user)
    locked_ids = wijaya_lock_assigned_conversation_ids(account, user)
    return [] if locked_ids.empty?

    # rubocop:disable Rails/SkipsModelValidations
    cleared_ids = Conversation.where(id: locked_ids, assignee_id: user.id).ids
    Conversation.where(id: cleared_ids).update_all(assignee_id: nil) if cleared_ids.present?
    # rubocop:enable Rails/SkipsModelValidations
    wijaya_record_agent_deletion_provenance(account, user, cleared_ids)
    cleared_ids
  end

  # FOR UPDATE on the conversations currently assigned to this user in this account; returns their
  # ids. The lock is held for the remainder of the enclosing transaction (capture, clear, provenance).
  def wijaya_lock_assigned_conversation_ids(account, user)
    user.assigned_conversations.where(account: account).lock.ids
  end

  def wijaya_bridge_agent_deletion_auto_assignment(account, conversation_ids)
    return if conversation_ids.blank?
    return unless defined?(Wijaya::Batteries::Core::Hooks)

    Wijaya::Batteries::Core::Hooks.dispatch(
      :deferred_auto_assignment, :on_agent_deletion_unassigned,
      default: nil, account_id: account.id, conversation_ids: conversation_ids
    )
  end

  # In-transaction, BEST-EFFORT provenance recording. The battery hook is savepoint-isolated and the
  # core dispatcher rescues everything, so a provenance failure can never roll back the user deletion
  # — which also means capture is NOT guaranteed: on failure the deletion still commits and that
  # tombstone is simply absent (unrecoverable), never an atomic all-or-nothing guarantee. The
  # deletion job_id keys each tombstone so retries of THIS deletion dedupe, while a later re-add and
  # re-deletion of the same conversation+agent records a distinct, independently reconcilable row.
  def wijaya_record_agent_deletion_provenance(account, user, conversation_ids)
    return if conversation_ids.blank?
    return unless defined?(Wijaya::Batteries::Core::Hooks)

    Wijaya::Batteries::Core::Hooks.dispatch(
      :deferred_auto_assignment, :record_agent_deletion_provenance,
      default: nil, account_id: account.id, prior_assignee_id: user.id,
      conversation_ids: conversation_ids, deletion_key: job_id
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
end
