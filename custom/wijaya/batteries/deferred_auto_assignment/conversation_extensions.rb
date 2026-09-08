# frozen_string_literal: true

# Attaches the deferred-assignment marker's lifecycle to core Conversation via to_prepare
# (see loader.rb), keeping app/models/conversation.rb free of any marker-specific cleanup.
#
# Two responsibilities, both battery-owned:
#
#   1. has_one :wijaya_deferred_assignment, dependent: :destroy
#      There is at most one marker per conversation (unique conversation_id). The SYNCHRONOUS
#      dependent: :destroy removes the child marker inline when the conversation is destroyed.
#      This is required, not optional: core destroys conversations through destroy_async /
#      DeleteObjectJob, and a custom child table with only a DB foreign key (no synchronous
#      dependent) makes that job raise an FK violation. Mirrors the erp_lead_sidebar battery.
#
#   2. after_update_commit cleanup — the moment a MARKED, waiting conversation stops being a
#      candidate for deferred native auto-assignment, drop its marker so no later
#      availability/presence trigger can act on stale state. It fires only when the committed
#      update made the conversation ineligible in a way the user asked to close out
#      immediately: a human assignee was set, an agent bot took ownership, or the status left
#      "open". It NEVER re-creates a marker (registration is creation-only), so a later manual
#      unassignment back to nil leaves the (already-absent) marker untouched and re-registers
#      nothing. delete_all keeps this a single narrow DELETE with no child callbacks.
#
#   3. after_update_commit capacity recovery — when a previously assigned conversation frees an
#      agent's assignment capacity (it left "open", or its assignee changed/cleared), enqueue a
#      coalesced, marker-gated pass for the inbox so a conversation still waiting on a marker can
#      now be assigned to that freed agent. It never re-creates a marker and is fail-open.
module Wijaya::Batteries::DeferredAutoAssignment::ConversationExtensions
  extend ActiveSupport::Concern

  included do
    has_one :wijaya_deferred_assignment,
            class_name: 'Wijaya::Batteries::DeferredAutoAssignment::Marker',
            dependent: :destroy

    after_update_commit :wijaya_cleanup_deferred_marker_if_ineligible
    after_update_commit :wijaya_recover_deferred_capacity_on_release
  end

  private

  def wijaya_cleanup_deferred_marker_if_ineligible
    return unless wijaya_deferred_marker_should_clear?

    Wijaya::Batteries::DeferredAutoAssignment::Marker.where(conversation_id: id).delete_all
  end

  # Assignment capacity for this inbox may have just freed up — a previously assigned
  # conversation either left the open status (resolved/snoozed) or changed/lost its assignee —
  # so an agent who was at capacity might now take a conversation still waiting on a marker in
  # the same inbox. enqueue_for_inbox is marker-gated and coalesced, so this is a cheap no-op
  # unless the inbox actually holds waiting work. Fail-open: recovery never breaks the commit.
  def wijaya_recover_deferred_capacity_on_release
    return unless wijaya_deferred_capacity_released?

    Wijaya::Batteries::DeferredAutoAssignment::TriggerService.enqueue_for_inbox(inbox_id)
  rescue StandardError => e
    Rails.logger.error("[Wijaya] deferred capacity recovery failed: #{e.class}")
  end

  # Only when a prior assignee actually occupied capacity (blank-before means nothing was held
  # to release): the conversation just left open, or its assignee changed/cleared.
  def wijaya_deferred_capacity_released?
    return false if assignee_id_before_last_save.blank?

    (saved_change_to_status? && !open?) || saved_change_to_assignee_id?
  end

  # Narrowly gated: a human assignee was just set, an agent bot just took ownership, or the
  # conversation just left the open status. Assignment back to nil (manual unassign) does not
  # match, so it never triggers cleanup and never re-registers.
  def wijaya_deferred_marker_should_clear?
    (saved_change_to_assignee_id? && assignee_id.present?) ||
      (saved_change_to_assignee_agent_bot_id? && assignee_agent_bot_id.present?) ||
      (saved_change_to_status? && !open?)
  end
end
