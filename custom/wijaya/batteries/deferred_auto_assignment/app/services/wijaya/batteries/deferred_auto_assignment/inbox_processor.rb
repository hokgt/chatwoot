# frozen_string_literal: true

# Processes the durable deferred markers for a single inbox, trying to assign each waiting
# conversation to an eligible online agent using the UNCHANGED native selector. Invoked by
# the coalesced ProcessInboxJob after an agent in this inbox becomes reachable.
#
# For each marker, the recheck + assignment happen under a database row lock on the freshly
# reloaded conversation (with_lock issues SELECT ... FOR UPDATE and reloads), so the row is
# serialized against concurrent writers, plus an explicit compare-and-set predicate is
# re-checked immediately before the write:
#   * every native gate is re-evaluated against the committed row state, not the stale marker;
#   * a concurrent SPV/manual assignment that committed BEFORE we take the lock is seen on
#     reload and skipped (never overwritten);
#   * a manual write that arrives WHILE we hold the lock is serialized after us and, because
#     it commits later, its assignee wins naturally over ours — we make no impossible claim
#     of absolute priority, only that the system assigns solely while the row is still open
#     and unclaimed at the instant of our write.
# We hold at most one conversation row lock at a time, so there is no cross-row deadlock.
#
# Marker lifecycle after processing one conversation:
#   * assigned by us            -> destroy (done);
#   * ineligible (resolved/snoozed/pending, already assigned by SPV, agent-bot owned, team
#     auto-assign turned off, moved to V2, inbox gone) -> destroy;
#   * still eligible but no online/capacity agent right now -> KEEP, for a later trigger.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module InboxProcessor
        module_function

        def process(inbox_id)
          return unless Inbox.exists?(id: inbox_id)

          Marker.where(inbox_id: inbox_id).find_each do |marker|
            process_marker(marker)
          end
        end

        def process_marker(marker)
          conversation = marker.conversation
          return marker.destroy if conversation.nil?

          keep = false
          conversation.with_lock do
            keep = try_assign(conversation)
          end
          marker.destroy unless keep
        rescue ActiveRecord::RecordNotFound
          marker.destroy
        end

        # Returns true to KEEP the marker (still eligible, nobody available yet), false to drop
        # it (assigned or no longer eligible). Runs inside the caller's row lock.
        def try_assign(conversation)
          return false unless Eligibility.deferrable?(conversation)

          allowed_agent_ids = Eligibility.allowed_agent_ids(conversation)
          assignee = AutoAssignment::AgentAssignmentService.new(
            conversation: conversation, allowed_agent_ids: allowed_agent_ids
          ).find_assignee
          return true if assignee.nil?

          # Final compare-and-set immediately before the write, still holding the FOR UPDATE
          # row lock: assign only while this locked+reloaded row is still open and unclaimed by
          # a human or an agent bot. update! (not update_all) preserves the native assignment
          # callbacks/events, including the automatic_assignment_activity marker that
          # find_assignee just set, so the normal "assigned by the System" activity still fires.
          return false unless assignable_now?(conversation)

          conversation.update!(assignee: assignee)
          false
        end

        # The conditional predicate for the final write: id match is implicit (same locked
        # row object), status still open, and neither a human nor an agent bot has claimed it.
        def assignable_now?(conversation)
          conversation.open? &&
            conversation.assignee_id.nil? &&
            conversation.assignee_agent_bot_id.nil?
        end
      end
    end
  end
end
