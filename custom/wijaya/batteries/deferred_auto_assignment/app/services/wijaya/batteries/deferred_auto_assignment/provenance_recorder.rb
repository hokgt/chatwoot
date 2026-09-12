# frozen_string_literal: true

# Records BEST-EFFORT deletion provenance for the exact conversations an agent deletion is about to
# clear. Invoked from inside Agents::DestroyJob's unassignment transaction (for exactly the rows it
# cleared under the FOR UPDATE lock), so a successful tombstone commits together with the
# unassignment — a crash between that commit and the existing post-commit dispatch leaves a
# structured, authoritative row the reconciliation can later act on, instead of an unmarked
# conversation that could only be guessed from free text.
#
# It wraps its writes in a SAVEPOINT (requires_new: true): if recording provenance fails for any
# reason, only the savepoint rolls back and the error propagates to the fail-open core dispatcher
# (which rescues it) — the enclosing user-deletion transaction is NOT poisoned and the deletion still
# commits. This preserves the battery's fail-open contract (a battery error must never roll back a
# user deletion). The direct consequence, stated plainly: capture is therefore BEST-EFFORT, NOT a
# guaranteed atomic completeness — on a recorder failure the deletion commits with that tombstone
# simply ABSENT, and (having no other authoritative source) that conversation stays unrecoverable by
# reconciliation. Normal deletion behavior is never blocked.
#
# Idempotent per deletion occurrence: the unique (conversation_id, prior_assignee_id, event,
# deletion_key) index means a retried DestroyJob (same job_id => same deletion_key) never
# double-records, while a genuinely later re-add and re-deletion of the same conversation+agent
# (a NEW job_id) records a distinct, independently reconcilable tombstone. No message content, no
# credentials — only structured ids, the event kind, the deletion key, and the event time.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module ProvenanceRecorder
        module_function

        def record_agent_deletion(account_id, prior_assignee_id, conversation_ids, deletion_key:)
          return if account_id.blank? || prior_assignee_id.blank? || conversation_ids.blank? || deletion_key.blank?

          shared = { account_id: account_id, prior_assignee_id: prior_assignee_id,
                     deletion_key: deletion_key, event_at: Time.current }
          # SAVEPOINT: isolate provenance failures from the enclosing user-deletion transaction.
          ActiveRecord::Base.transaction(requires_new: true) do
            rows_for(account_id, conversation_ids).each do |conversation_id, inbox_id|
              upsert_row(conversation_id, inbox_id, shared)
            end
          end
        end

        # Only conversations that (still) belong to this account are recorded — a stray
        # cross-account id can never produce a tombstone. inbox_id is captured for the later
        # coalesced per-inbox reconciliation pass.
        def rows_for(account_id, conversation_ids)
          Conversation.where(account_id: account_id, id: conversation_ids).pluck(:id, :inbox_id)
        end

        # find_or_create_by! keyed on the unique (conversation_id, prior_assignee_id, event,
        # deletion_key) index so a re-dispatch of the SAME deletion (same deletion_key) never
        # double-records, while a distinct later deletion occurrence (new deletion_key) inserts a new row.
        def upsert_row(conversation_id, inbox_id, shared)
          DeletionProvenance.find_or_create_by!(
            conversation_id: conversation_id,
            prior_assignee_id: shared[:prior_assignee_id],
            event: DeletionProvenance::AGENT_DELETION,
            deletion_key: shared[:deletion_key]
          ) do |row|
            row.account_id = shared[:account_id]
            row.inbox_id = inbox_id
            row.event_at = shared[:event_at]
          end
        end
      end
    end
  end
end
