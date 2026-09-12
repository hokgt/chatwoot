# frozen_string_literal: true

# Owns the agent-deletion unassignment for the deferred/native auto-assignment battery. Invoked
# from inside Agents::DestroyJob's enclosing user-deletion transaction (through the fail-open core
# dispatcher), so all the lock/compare-and-set/provenance business logic lives here rather than in
# the native job — the core file keeps only a tiny marker-wrapped dispatch + fallback.
#
# The single entry point row-locks (FOR UPDATE) the conversations currently assigned to the deleted
# agent in this account, clears ONLY the rows still owned by that agent while the lock is held (a
# conditional compare-and-set that also defends against any write the lock could not have
# serialized), records BEST-EFFORT provenance for precisely the cleared rows, and returns exactly
# those ids for the post-commit reassignment bridge. A concurrent manual reassignment is serialized
# either fully before our lock (excluded from every step) or fully after our commit (it wins), so a
# deletion can never clear — nor record a tombstone for — a conversation it did not actually
# unassign. Returns [] when the agent owns nothing (a retried deletion is a safe no-op).
#
# Provenance capture is best-effort/fail-open (see ProvenanceRecorder): a recorder failure raises
# out through the fail-open dispatcher (which rescues it and returns the native default), leaving
# that tombstone absent while the clear still commits — never a guaranteed atomic completeness.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module AgentDeletionUnassignment
        module_function

        def unassign(account_id:, user_id:, deletion_key:)
          locked_ids = lock_assigned_conversation_ids(account_id, user_id)
          return [] if locked_ids.empty?

          # rubocop:disable Rails/SkipsModelValidations
          cleared_ids = Conversation.where(id: locked_ids, assignee_id: user_id).ids
          Conversation.where(id: cleared_ids).update_all(assignee_id: nil) if cleared_ids.present?
          # rubocop:enable Rails/SkipsModelValidations
          ProvenanceRecorder.record_agent_deletion(account_id, user_id, cleared_ids, deletion_key: deletion_key)
          cleared_ids
        end

        # FOR UPDATE on the conversations currently assigned to this user in this account; returns
        # their ids. The lock is held for the remainder of the enclosing transaction (capture,
        # clear, provenance) — equivalent to the deleted user's assigned_conversations scope.
        def lock_assigned_conversation_ids(account_id, user_id)
          Conversation.where(account_id: account_id, assignee_id: user_id).lock.ids
        end
      end
    end
  end
end
