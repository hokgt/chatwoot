# frozen_string_literal: true

# Thin hook surface for the deferred/native auto-assignment battery, resolved by name from
# the generic core dispatcher (Wijaya::Batteries::Core::Hooks). Three native seams:
#
#   register_unassigned_on_create(conversation:)   Conversation after_create_commit — durably
#                                                  mark a brand-new conversation that finished
#                                                  creation-time native auto-assignment with no
#                                                  eligible online agent (Registrar decides).
#   on_agent_available(account_id:, user_id:, previous_availability:, current_availability:)
#                                                  AccountUser after_commit — an actual
#                                                  offline/busy -> online availability change
#                                                  processes that agent's waiting inboxes.
#   on_agent_present(account_id:, user_id:)        RoomChannel — an actual absent -> present
#                                                  User presence change (already detected at the
#                                                  seam) processes that agent's waiting inboxes.
#   on_inbox_member_added(inbox_id:)               InboxMember after_create — a newly added inbox
#                                                  agent may be the first eligible one; processes
#                                                  that inbox's waiting markers (marker-gated).
#   on_team_member_added(account_id:, team_id:)    TeamMember after_create — a newly added team
#                                                  agent may be the first eligible one; processes
#                                                  waiting markers on that team's inboxes.
#
# All heavy lifting lives in the service objects; this surface only translates a native call
# into a battery action. Every method is safe to fail: the core dispatcher rescues anything.
# Nested (not compact) so the unqualified sibling references (Registrar, TriggerService)
# resolve lexically to Wijaya::Batteries::DeferredAutoAssignment::*.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module Hooks
        module_function

        def register_unassigned_on_create(conversation:)
          Registrar.register_unassigned_on_create(conversation)
        end

        def on_agent_available(account_id:, user_id:, previous_availability:, current_availability:)
          return unless current_availability.to_s == 'online'
          return unless %w[offline busy].include?(previous_availability.to_s)

          TriggerService.enqueue_for_agent(account_id: account_id, user_id: user_id)
        end

        def on_agent_present(account_id:, user_id:)
          TriggerService.enqueue_for_agent(account_id: account_id, user_id: user_id)
        end

        def on_inbox_member_added(inbox_id:)
          TriggerService.enqueue_for_inbox(inbox_id)
        end

        def on_team_member_added(account_id:, team_id:)
          TriggerService.enqueue_for_team(account_id: account_id, team_id: team_id)
        end
      end
    end
  end
end
