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
# Marker lifecycle after processing one conversation (via Marker.resolve_and_record /
# Marker.record_waiting, which also record the run-ledger disposition for a reconciliation-owned
# marker — an ordinary marker is simply removed/kept exactly as before):
#   * assigned by us            -> resolve (ASSIGNED), done;
#   * ineligible (resolved/snoozed/pending, already assigned by SPV, agent-bot owned, team
#     auto-assign turned off, moved to V2, inbox gone) -> resolve (DROPPED);
#   * still eligible but no online/capacity agent right now -> KEEP (NO_ELIGIBLE_AGENT), for a
#     later trigger; the ledger counts the conversation once, not once per no-agent pass.
#
# For a reconciliation-adopted marker this is the ONLY place the actual assignment outcome is
# truthfully known, so it is where the run ledger's assigned / no_eligible_agent / dropped counters
# are recorded and correlated back to the generation the Reconciler stamped on the marker.
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
          if conversation.nil?
            log_outcome(marker, 'dropped_conversation_missing')
            return Marker.resolve_and_record(marker.conversation_id, ReconciliationRun::DROPPED)
          end

          outcome = :dropped_ineligible
          conversation.with_lock { outcome = try_assign(conversation) }
          record_result(marker, outcome)
        rescue ActiveRecord::RecordNotFound
          log_outcome(marker, 'dropped_not_found')
          Marker.resolve_and_record(marker.conversation_id, ReconciliationRun::DROPPED)
        end

        # Runs inside the caller's row lock and returns a disposition symbol; it performs the
        # assignment and, on success, resolves the marker as ASSIGNED WITHIN the same lock
        # transaction so the assignment and the ledger 'assigned' commit atomically (the post-commit
        # lifecycle cleanup then finds no marker and records nothing, so a system assignment can
        # never be mis-recorded as dropped). Non-assignment outcomes are resolved by record_result
        # after the lock releases.
        #   :assigned            native selector claimed it (marker already resolved here)
        #   :no_eligible_agent   still eligible, nobody available yet -> keep the marker
        #   :dropped_ineligible / :dropped_claimed -> drop the marker
        def try_assign(conversation)
          return :dropped_ineligible unless Eligibility.deferrable?(conversation)

          allowed_agent_ids = Eligibility.allowed_agent_ids(conversation)
          assignee = AutoAssignment::AgentAssignmentService.new(
            conversation: conversation, allowed_agent_ids: allowed_agent_ids
          ).find_assignee
          return :no_eligible_agent if assignee.nil?

          # Final compare-and-set immediately before the write, still holding the FOR UPDATE
          # row lock: assign only while this locked+reloaded row is still open and unclaimed by
          # a human or an agent bot. update! (not update_all) preserves the native assignment
          # callbacks/events, including the automatic_assignment_activity marker that
          # find_assignee just set, so the normal "assigned by the System" activity still fires.
          return :dropped_claimed unless assignable_now?(conversation)

          conversation.update!(assignee: assignee)
          Marker.resolve_and_record(conversation.id, ReconciliationRun::ASSIGNED)
          :assigned
        end

        # Records the per-marker outcome (content-free log for EVERY marker + ledger disposition for
        # reconciliation-owned ones) and finalizes the marker lifecycle: assigned markers are already
        # resolved atomically inside the lock; a no-eligible-agent marker is KEPT (counted once) for a
        # later trigger; everything else is dropped.
        def record_result(marker, outcome)
          case outcome
          when :assigned
            log_outcome(marker, 'assigned')
          when :no_eligible_agent
            log_outcome(marker, 'no_eligible_agent_marker_retained')
            Marker.record_waiting(marker.conversation_id)
          else
            log_outcome(marker, outcome.to_s)
            Marker.resolve_and_record(marker.conversation_id, ReconciliationRun::DROPPED)
          end
        end

        # Content-free: conversation id, outcome, and (for correlation) the reconciliation
        # generation when this marker was adopted by a reconciliation run. Never message bodies or
        # assignee names.
        def log_outcome(marker, outcome)
          generation = marker.reconciliation_generation
          suffix = generation.present? ? " reconciliation_generation=#{generation}" : ''
          Rails.logger.info("[Wijaya] deferred assignment conversation=#{marker.conversation_id} outcome=#{outcome}#{suffix}")
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
