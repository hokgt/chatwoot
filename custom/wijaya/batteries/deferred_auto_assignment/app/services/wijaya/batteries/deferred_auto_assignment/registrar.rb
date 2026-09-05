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
        end
      end
    end
  end
end
