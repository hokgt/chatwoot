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
# Both funnel through AgentAssignmentService#find_assignee, so a single :native mark
# there tags every legacy auto-assignment; the tag is later read at activity-creation.
#
#   Path C  AutoAssignment::AssignmentService#claim_and_assign (Assignment V2 bulk job).
#           This path DOES name an actor — it sets Current.executed_by to the inbox's own
#           assignment policy (or the inbox) around the claiming update! — so upstream
#           writes a badge, but reading "... by Default Policy" / "... by Automation
#           System via <policy>" rather than the required "... by the System". Here we
#           stamp the exact claimed row with a :v2 mark so actor_for OVERRIDES that
#           self-set policy actor with "the System". Because the mark is placed only at
#           the auto-assignment claim seam, this override is scoped to V2 auto-assignment
#           and never relabels a genuine AutomationRule/AssignmentPolicy assignment made
#           elsewhere.
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
# The actor is only ever "the System" when an auto-assignment mark is present AND no
# human (Current.user) owns the change. For a :native mark we additionally defer to any
# more-specific automation actor (Current.executed_by, e.g. an AutomationRule/
# AssignmentPolicy), since the native paths set none themselves. A :v2 mark is placed
# exactly at the V2 claim seam where executed_by is the auto-assignment policy the
# service set for itself, so that (and only that) policy actor is overridden. Manual/API
# assignment keeps its human actor; automation done outside the auto-assignment seams
# keeps its policy actor; and only genuine auto-assignment is labelled System.
module Wijaya
  module Batteries
    module AutomaticAssignmentActivity
      module SystemAssignment
        MARKER = :@wijaya_system_auto_assignment

        module_function

        # Path A/B: stamp the conversation instance whose assignment callbacks will fire.
        # No actor is set on these paths, so the badge is only ADDED, never overridden.
        def mark(conversation)
          conversation.instance_variable_set(MARKER, :native)
          true
        end

        # Path C (Assignment V2): stamp the exact claimed row. V2 sets its own policy
        # actor (Current.executed_by), so this mark tells actor_for to OVERRIDE it with
        # "the System" instead of merely adding a missing badge.
        def mark_v2(conversation)
          conversation.instance_variable_set(MARKER, :v2)
          true
        end

        # Read-and-consume: returns the localized "the System" actor label when this
        # assignee change was made by auto-assignment and should be attributed to the
        # System; otherwise nil, so the caller falls through to unchanged native behavior.
        def actor_for(conversation, user_name)
          kind = consume!(conversation)
          return nil unless kind
          return nil if user_name.present?
          # :native paths set no actor, so defer to any real automation actor present.
          # :v2 deliberately overrides the auto-assignment policy actor it set for itself.
          return nil if kind == :native && Current.executed_by.present?
          return nil unless conversation.saved_change_to_assignee_id? && conversation.assignee_id.present?

          I18n.t('auto_assignment.system_actor')
        end

        # Returns the mark kind (:native/:v2) and clears it, so a mark is honoured once.
        def consume!(conversation)
          return nil unless conversation.instance_variable_defined?(MARKER)

          conversation.remove_instance_variable(MARKER)
        end
      end
    end
  end
end
