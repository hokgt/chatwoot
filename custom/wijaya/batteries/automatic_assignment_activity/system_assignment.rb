# frozen_string_literal: true

# Business logic for the automatic-assignment activity battery.
#
# THE GAP THIS CLOSES
# -------------------
# Native Chatwoot only records an "Assigned to X by <actor>" timeline activity when it
# can name an actor: AssignueeActivityMessageHandler#activity_message_owner returns nil
# (and the activity is skipped) unless there is a Current.user or a Current.executed_by.
# The two NATIVE auto-assignment code paths that assign an agent WITHOUT setting either
# actor therefore produce no badge at all:
#   Path A  AssignmentHandler#ensure_assignee_is_from_team (before_save, team routing —
#           e.g. Meta Ads Ad->Team) -> AgentAssignmentService#find_assignee
#   Path B  AutoAssignmentHandler#run_auto_assignment (after_save, legacy inbox
#           round-robin) -> AgentAssignmentService#perform -> #find_assignee
# Both funnel through AgentAssignmentService#find_assignee, so a single mark there tags
# every native auto-assignment; the tag is later read at activity-creation time.
#
# WHY A PER-CONVERSATION INSTANCE MARK (not a Current.* thread flag)
# -----------------------------------------------------------------
# The mark is set during before_save (Path A) and read during after_commit; a thread
# flag set in before_save would either be cleared too early (before after_commit) or
# leak to unrelated work if the transaction rolls back. Stamping the exact Conversation
# instance that carries both callbacks scopes the signal precisely to this assignment,
# needs no cleanup on rollback (the instance is discarded), and is consumed once when
# read so it can never label a later manual reassignment on a reused instance.
#
# FAIL SAFE
# ---------
# The actor is only ever "the System" when a native auto-assignment mark is present AND
# no human (Current.user) and no more-specific automation actor (Current.executed_by,
# e.g. an AutomationRule or AssignmentPolicy) owns the change. So manual/API assignment
# keeps its human actor, automation keeps its policy actor, and only genuinely native
# auto-assignment is labelled System.
module Wijaya
  module Batteries
    module AutomaticAssignmentActivity
      module SystemAssignment
        MARKER = :@wijaya_system_auto_assignment

        module_function

        # Path A/B: stamp the conversation instance whose assignment callbacks will fire.
        def mark(conversation)
          conversation.instance_variable_set(MARKER, true)
          true
        end

        # Read-and-consume: returns the localized "the System" actor label when this
        # assignee change was made by native auto-assignment and no other actor owns it;
        # otherwise nil, so the caller falls through to unchanged native behavior.
        def actor_for(conversation, user_name)
          return nil unless consume!(conversation)
          return nil if user_name.present?
          return nil if Current.executed_by.present?
          return nil unless conversation.saved_change_to_assignee_id? && conversation.assignee_id.present?

          I18n.t('auto_assignment.system_actor')
        end

        def consume!(conversation)
          return false unless conversation.instance_variable_defined?(MARKER)

          conversation.remove_instance_variable(MARKER)
        end
      end
    end
  end
end
