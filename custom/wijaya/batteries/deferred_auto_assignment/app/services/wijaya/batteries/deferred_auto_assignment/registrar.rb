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
      end
    end
  end
end
