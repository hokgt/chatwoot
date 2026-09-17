# frozen_string_literal: true

# Owns the final orphaned-User deletion for the agent-deletion race fix. Called from the TAIL of
# Agents::DestroyJob (through the fail-open core dispatcher) only after that job's
# provenance/unassignment transaction has committed and the reassignment bridge has dispatched, so
# the User is deleted strictly LAST — it can never FK-clear conversations.assignee_id before the
# deletion provenance is captured (the original sibling-DeleteObjectJob race that lost provenance).
#
# Rechecks memberships so a User that still belongs to another account (a multi-account agent) is
# preserved, mirroring the original controller guard. It ENQUEUES the native DeleteObjectJob rather
# than destroying inline, so the actual teardown runs exactly as upstream. It returns true whenever
# it has authoritatively handled the decision (enqueued a deletion, or correctly declined because
# the User still has memberships / is already gone) so the native caller skips its fallback; if it
# raises, the core dispatcher rescues it and the caller's native fallback still deletes the orphan.
#
# Idempotency lives at the DeleteObjectJob layer: the User is carried by GlobalID, and once it is
# gone a retried DeleteObjectJob (or a retried Agents::DestroyJob, whose own user argument no longer
# deserializes) fails GlobalID deserialization and is DISCARDED by ApplicationJob's
# `discard_on ActiveJob::DeserializationError` — it is not re-run as a harmless no-op.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module OrphanedUserFinalizer
        module_function

        def finalize(user_id:)
          user = User.find_by(id: user_id)
          return true if user.nil? # already deleted -> nothing to do, still authoritatively handled

          DeleteObjectJob.perform_later(user) if user.account_users.blank?
          true
        end
      end
    end
  end
end
