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

        # A single inbox became a processing candidate (new member, freed capacity, or the
        # registrar closing the trigger-before-marker race). Marker-gated so it is a no-op unless
        # the inbox actually holds waiting work, then coalesced by the job's in-flight key.
        def enqueue_for_inbox(inbox_id)
          return unless Marker.exists?(inbox_id: inbox_id)

          ProcessInboxJob.enqueue_for_inbox(inbox_id)
        end

        # A team gained a member: process exactly the inboxes that hold a marker for a
        # conversation routed to that team (the STORED team_id), never a blanket inbox scan.
        def enqueue_for_team(account_id:, team_id:)
          team_marked_inbox_ids(account_id, team_id).each do |inbox_id|
            ProcessInboxJob.enqueue_for_inbox(inbox_id)
          end
        end

        def team_marked_inbox_ids(account_id, team_id)
          Marker.joins(:conversation)
                .where(account_id: account_id, conversations: { team_id: team_id })
                .distinct.pluck(:inbox_id)
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
