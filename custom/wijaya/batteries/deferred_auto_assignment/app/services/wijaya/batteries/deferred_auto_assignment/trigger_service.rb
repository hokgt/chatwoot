# frozen_string_literal: true

# Turns an agent-availability/presence transition into deferred-assignment processing.
# Given the account + user that just became reachable (offline/busy -> online, or absent ->
# present), it enqueues a coalesced per-inbox processing job for exactly the inboxes that
# (a) the agent is a member of, in that account, AND (b) currently hold a deferred marker.
# It never scans all unassigned conversations: the marker table is the bounded work-list,
# and the agent's inbox memberships bound it further to inboxes this transition can affect.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module TriggerService
        module_function

        def enqueue_for_agent(account_id:, user_id:)
          candidate_inbox_ids(account_id, user_id).each do |inbox_id|
            ProcessInboxJob.enqueue_for_inbox(inbox_id)
          end
        end

        def candidate_inbox_ids(account_id, user_id)
          member_inbox_ids = InboxMember.joins(:inbox)
                                        .where(user_id: user_id, inboxes: { account_id: account_id })
                                        .pluck(:inbox_id)
          return [] if member_inbox_ids.empty?

          Marker.where(account_id: account_id, inbox_id: member_inbox_ids).distinct.pluck(:inbox_id)
        end
      end
    end
  end
end
