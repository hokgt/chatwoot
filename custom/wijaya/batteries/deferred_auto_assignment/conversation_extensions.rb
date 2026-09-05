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
module Wijaya::Batteries::DeferredAutoAssignment::ConversationExtensions
  extend ActiveSupport::Concern

  included do
    has_one :wijaya_deferred_assignment,
            class_name: 'Wijaya::Batteries::DeferredAutoAssignment::Marker',
            dependent: :destroy

    after_update_commit :wijaya_cleanup_deferred_marker_if_ineligible
  end

  private

  def wijaya_cleanup_deferred_marker_if_ineligible
    return unless wijaya_deferred_marker_should_clear?

    Wijaya::Batteries::DeferredAutoAssignment::Marker.where(conversation_id: id).delete_all
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
