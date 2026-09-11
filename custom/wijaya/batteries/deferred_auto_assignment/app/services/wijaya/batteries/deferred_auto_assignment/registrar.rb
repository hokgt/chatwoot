# frozen_string_literal: true

# Registers a durable deferred marker for a brand-new conversation that just completed its
# creation-time native legacy auto-assignment without landing an assignee, because no
# eligible ONLINE agent existed. Called from the Conversation after_create_commit seam, so
# it runs exactly once, only at creation, and only after the row (and its in-transaction
# immediate-assignment attempt) has committed — a later manual/SPV unassignment can never
# reach here. Idempotent: find_or_create keyed on the unique conversation_id.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module Registrar
        module_function

        def register_unassigned_on_create(conversation)
          return unless Eligibility.deferrable?(conversation)

          Marker.find_or_create_by!(conversation_id: conversation.id) do |marker|
            marker.account_id = conversation.account_id
            marker.inbox_id = conversation.inbox_id
          end

          # Close the trigger-before-marker race: an agent who became reachable AFTER the
          # creation-time assignment attempt but BEFORE this marker existed would have found no
          # marker to act on, and no later trigger is guaranteed. A coalesced, marker-gated pass
          # now assigns immediately if an eligible agent is already available.
          ProcessInboxJob.enqueue_for_inbox(conversation.inbox_id)
        end

        # Bridge for an agent deletion: Agents::DestroyJob has already cleared this agent's
        # assignee_id via update_all (callbacks skipped), so the affected conversations are now
        # open + unassigned but carry no marker. Re-run native legacy auto-assignment for exactly
        # those conversations — mark each still-eligible one (idempotent find_or_create keyed on
        # the unique conversation_id, so a retried DestroyJob never double-marks) and enqueue a
        # coalesced pass for each affected inbox. The InboxProcessor then assigns an eligible
        # online agent under a row lock, or the marker waits for a later availability/presence
        # trigger. Only account-scoped ids from this deletion are considered — never a blanket
        # scan. Runs after the deletion transaction commits (see Agents::DestroyJob).
        #
        # Retry / crash window: a normal ActiveJob retry re-runs the whole DestroyJob; by then the
        # agent owns no conversations, so the bridge collects an empty id list and this is a no-op,
        # and the unique conversation_id keeps find_or_create_by! from double-marking even if the
        # SAME ids are re-dispatched. The one irreducible gap is a process SIGKILL AFTER the
        # unassignment transaction commits but BEFORE the post-commit dispatch runs: those
        # conversations are then unassigned with no marker and no trigger. It is left irreducible
        # deliberately — closing it would mean either marking INSIDE the deletion transaction
        # (coupling the battery in so a marker error could roll back a user deletion, breaking the
        # fail-open contract) or a broad account-wide unassigned scan (out of scope). A later manual
        # assignment or a fresh inbound still resolves such a conversation normally.
        def register_unassigned_after_agent_deletion(account_id, conversation_ids)
          affected_inbox_ids = []
          Conversation.where(account_id: account_id, id: conversation_ids).find_each do |conversation|
            next unless Eligibility.deferrable?(conversation)

            Marker.find_or_create_by!(conversation_id: conversation.id) do |marker|
              marker.account_id = conversation.account_id
              marker.inbox_id = conversation.inbox_id
            end
            affected_inbox_ids << conversation.inbox_id
          end
          affected_inbox_ids.uniq.each { |inbox_id| ProcessInboxJob.enqueue_for_inbox(inbox_id) }
        end
      end
    end
  end
end
