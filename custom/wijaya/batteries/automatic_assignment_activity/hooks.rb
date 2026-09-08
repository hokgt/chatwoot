# frozen_string_literal: true

require_relative 'system_assignment'

# Thin hook surface for the automatic-assignment activity battery, resolved by the
# generic core dispatcher (Wijaya::Batteries::Core::Hooks). Three seams:
#
#   mark_system_assignment(conversation:)      called from the legacy AutoAssignment
#                                              service when it picks an agent, to tag
#                                              the assignment as system-performed.
#   mark_v2_system_assignment(conversation:)   called from AssignmentService (V2 bulk
#                                              job) at the claim/update seam, to tag the
#                                              claimed row so its self-set policy actor
#                                              is overridden with "the System".
#   system_assignment_actor(conversation:, user_name:)  called at activity-creation
#                                              time; returns the "the System" actor
#                                              label for a tagged auto-assignment, else
#                                              nil (native).
#
# Nested (not compact `module Wijaya::Batteries::AutomaticAssignmentActivity::Hooks`)
# so the unqualified `SystemAssignment` reference resolves lexically and the file is
# standalone-safe when required directly by the loader before the parent namespace
# exists; a compact form would raise NameError and the core dispatcher would fail open.
module Wijaya
  module Batteries
    module AutomaticAssignmentActivity
      module Hooks
        module_function

        def mark_system_assignment(conversation:)
          SystemAssignment.mark(conversation)
        end

        def mark_v2_system_assignment(conversation:)
          SystemAssignment.mark_v2(conversation)
        end

        def system_assignment_actor(conversation:, user_name:)
          SystemAssignment.actor_for(conversation, user_name)
        end
      end
    end
  end
end
