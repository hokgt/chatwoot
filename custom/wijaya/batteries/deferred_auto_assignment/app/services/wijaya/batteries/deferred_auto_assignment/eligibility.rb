# frozen_string_literal: true

# Single source of truth for "would native legacy creation-time auto-assignment have
# assigned an agent to this conversation, and is it still waiting for one?". Used both at
# registration (Registrar, right after creation) and at processing time (InboxProcessor,
# under a row lock on the reloaded row), so the two can never drift.
#
# The predicate mirrors the exact native legacy gates:
#   * conversation open, human-unassigned (assignee_id nil), and not owned by an agent bot;
#   * the inbox is on the LEGACY path (Assignment V2 disabled) — V2 is never touched here;
#   * native auto-assignment is applicable:
#       - team conversation  -> team.allow_auto_assign? (AssignmentHandler's before_save team
#         routing runs regardless of the inbox toggle, so this is the governing gate);
#       - non-team conversation -> inbox.enable_auto_assignment? (AutoAssignmentHandler).
#
# allowed_agent_ids reproduces AutoAssignmentHandler#run_auto_assignment byte-for-byte:
# team conversations intersect inbox capacity members with team members; others use inbox
# capacity members. The battery never invents a selector — the caller feeds these ids to
# the native AutoAssignment::AgentAssignmentService, which applies online/round-robin.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module Eligibility
        module_function

        def deferrable?(conversation)
          inbox = conversation&.inbox
          return false if inbox.nil?
          return false unless conversation.open?
          return false if conversation.assignee_id.present?
          return false if conversation.assignee_agent_bot_id.present?
          return false if inbox.auto_assignment_v2_enabled?

          native_auto_assignment_applicable?(conversation, inbox)
        end

        def native_auto_assignment_applicable?(conversation, inbox)
          if conversation.team_id.present?
            conversation.team&.allow_auto_assign?
          else
            inbox.enable_auto_assignment?
          end
        end

        def allowed_agent_ids(conversation)
          inbox = conversation.inbox
          if conversation.team_id.present?
            team_member_ids_with_capacity(conversation, inbox)
          else
            inbox.member_ids_with_assignment_capacity
          end
        end

        def team_member_ids_with_capacity(conversation, inbox)
          team = conversation.team
          return [] if team.blank? || team.allow_auto_assign.blank?

          inbox.member_ids_with_assignment_capacity & team.members.ids
        end
      end
    end
  end
end
