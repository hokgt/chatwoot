# frozen_string_literal: true

# Records durable deletion provenance for the exact conversations an agent deletion is about to
# clear. Invoked from inside Agents::DestroyJob's unassignment transaction (before the update_all),
# so the tombstone commits ATOMICALLY with the unassignment — a crash between that commit and the
# existing post-commit dispatch leaves a structured, authoritative row the one-time reconciliation
# can later act on, instead of an unmarked conversation that could only be guessed from free text.
#
# Crucially it wraps its writes in a SAVEPOINT (requires_new: true): if recording provenance fails
# for any reason, only the savepoint rolls back and the error propagates to the fail-open core
# dispatcher (which rescues it) — the enclosing user-deletion transaction is NOT poisoned and the
# deletion still commits. This preserves the battery's fail-open contract (a battery error must
# never roll back a user deletion) while still recording provenance in the same transaction.
#
# Idempotent: the unique (conversation_id, prior_assignee_id, event) index means a retried
# DestroyJob that re-dispatches the same ids never double-records. No message content, no
# credentials — only structured ids, the event kind, and the event time.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module ProvenanceRecorder
        module_function

        def record_agent_deletion(account_id, prior_assignee_id, conversation_ids)
          return if account_id.blank? || prior_assignee_id.blank? || conversation_ids.blank?

          event_at = Time.current
          # SAVEPOINT: isolate provenance failures from the enclosing user-deletion transaction.
          ActiveRecord::Base.transaction(requires_new: true) do
            rows_for(account_id, conversation_ids).each do |conversation_id, inbox_id|
              upsert_row(account_id, conversation_id, inbox_id, prior_assignee_id, event_at)
            end
          end
        end

        # Only conversations that (still) belong to this account are recorded — a stray
        # cross-account id can never produce a tombstone. inbox_id is captured for the later
        # coalesced per-inbox reconciliation pass.
        def rows_for(account_id, conversation_ids)
          Conversation.where(account_id: account_id, id: conversation_ids).pluck(:id, :inbox_id)
        end

        # find_or_create_by! keyed on the unique (conversation_id, prior_assignee_id, event) index
        # so a re-dispatch of the same deletion never double-records.
        def upsert_row(account_id, conversation_id, inbox_id, prior_assignee_id, event_at)
          DeletionProvenance.find_or_create_by!(
            conversation_id: conversation_id,
            prior_assignee_id: prior_assignee_id,
            event: DeletionProvenance::AGENT_DELETION
          ) do |row|
            row.account_id = account_id
            row.inbox_id = inbox_id
            row.event_at = event_at
          end
        end
      end
    end
  end
end
