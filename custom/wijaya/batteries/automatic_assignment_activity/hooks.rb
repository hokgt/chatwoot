# frozen_string_literal: true

require_relative 'system_assignment'

# Thin hook surface for the automatic-assignment activity battery, resolved by the
# generic core dispatcher (Wijaya::Batteries::Core::Hooks). Two seams:
#
#   mark_system_assignment(conversation:)      called from the native AutoAssignment
#                                              service when it picks an agent, to tag
#                                              the assignment as system-performed.
#   system_assignment_actor(conversation:, user_name:)  called at activity-creation
#                                              time; returns the "the System" actor
#                                              label for a tagged, actor-less
#                                              auto-assignment, else nil (native).
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

        def system_assignment_actor(conversation:, user_name:)
          SystemAssignment.actor_for(conversation, user_name)
        end
      end
    end
  end
end
