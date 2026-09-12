# frozen_string_literal: true

# Durable, per-conversation marker recording that a brand-new conversation completed its
# creation-time native (legacy) auto-assignment but found no eligible ONLINE agent, so it
# is waiting for one to become available. The conversation itself stays open with a nil
# assignee (no new status, naturally visible in Unassigned/All); this row is the only
# state the battery adds. It is created once at conversation creation (Registrar), consumed
# when a later agent-availability/presence transition lets processing assign the
# conversation (InboxProcessor), and destroyed on assignment or on becoming ineligible.
#
# There is exactly one marker per conversation (unique conversation_id), and inbox_id is
# stored so a trigger for a given agent can query only the markers for the inboxes that
# agent belongs to — never a blanket scan of all unassigned conversations.
#
# Lifecycle cleanup (destroy on conversation delete, on manual/bot assignment, on becoming
# non-open) is owned by the battery's ConversationExtensions concern, not by core.
#
# Lock order (deadlock-free): resolve_and_record / record_waiting take SELECT ... FOR UPDATE on the
# marker row, then update the ReconciliationRun ledger row — i.e. marker -> run. The InboxProcessor's
# ASSIGNED path is the ONLY caller holding another lock when it calls resolve_and_record: it is
# already inside conversation.with_lock, so its full order is conversation -> marker -> run. Every
# other caller (InboxProcessor#record_result's no_eligible_agent/dropped resolution, and the
# ConversationExtensions after_update_commit cleanup) acquires the marker lock with NO conversation
# lock held — record_result runs after with_lock releases, and the cleanup fires post-commit. So no
# caller ever takes marker-before-conversation, and the Reconciler never FOR-UPDATEs a marker (it only
# INSERTs new ones and updates the run row); the single global order conversation -> marker -> run has
# no cycle.
#
# Nested (not compact `class Wijaya::Batteries::DeferredAutoAssignment::Marker`) to match the
# sibling battery files, whose unqualified cross-references resolve lexically; kept uniform.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      class Marker < ApplicationRecord
        self.table_name = 'wijaya_deferred_assignments'

        belongs_to :account
        belongs_to :inbox
        belongs_to :conversation

        validates :conversation_id, uniqueness: true

        # Terminal accounting for the has_one dependent: :destroy path. When a conversation is
        # destroyed, its marker is removed via marker.destroy (NOT the delete_all that
        # resolve_and_record / record_waiting use), so those ledger transitions are bypassed. This
        # after_destroy runs INSIDE the destroy transaction and, for a reconciliation-owned marker,
        # records the terminal DROPPED disposition — reversing whatever bucket the marker last held
        # (reconciliation_outcome) exactly once — so a conversation/marker deletion can never leave a
        # run counter stuck (e.g. permanently no_eligible_agent) or double-counted. It is a no-op for
        # an ordinary marker (blank generation), and delete_all removals never fire it (no double count).
        after_destroy :wijaya_record_terminal_disposition

        # Remove the marker for +conversation_id+ and, when it was adopted by a reconciliation
        # generation, record its terminal +outcome+ (ReconciliationRun::ASSIGNED / DROPPED) so the
        # run ledger reflects each identified conversation's latest, unique disposition. Single-shot
        # under concurrency: the delete row-count gate means two racing removers (e.g. the
        # InboxProcessor assignment and the post-commit lifecycle cleanup) apply the ledger
        # transition at most once — the first to delete the row wins. A no-op when no marker exists.
        # Ordinary markers (generation nil) are simply deleted, exactly as before.
        #
        # ATOMIC: the marker delete and the ledger counter transition run in ONE transaction, so a
        # crash/raise between them can never leave the marker gone while the run counter is
        # untransitioned (or vice versa) — either both apply or neither does. If record_outcome
        # raises, the delete rolls back and the marker survives for a later, complete resolution.
        # When invoked inside a caller-supplied transaction (e.g. the InboxProcessor row lock) this
        # is a savepoint, still atomic with the assignment.
        #
        # RACE-SAFE: the marker row is locked SELECT ... FOR UPDATE and its generation/previous
        # disposition are (re-)read INSIDE the transaction, AFTER the lock is acquired — never from a
        # stale pre-transaction find_by. Without the lock a concurrent record_waiting could move the
        # marker nil -> NO_ELIGIBLE_AGENT (bumping that counter) in the window between our read and our
        # delete; we would then delete the row but pass a stale previous=nil to record_outcome, leaving
        # no_eligible_agent=1 AND assigned=1 for one conversation — two live buckets, violating the
        # latest-unique-disposition invariant. Reading previous under the lock guarantees record_outcome
        # decrements whatever bucket the marker actually holds now, so exactly one bucket survives.
        def self.resolve_and_record(conversation_id, outcome)
          transaction do
            marker = lock.find_by(conversation_id: conversation_id)
            next if marker.nil?

            generation = marker.reconciliation_generation
            previous = marker.reconciliation_outcome
            deleted = where(conversation_id: conversation_id).delete_all
            ReconciliationRun.record_outcome(generation, outcome, previous) if deleted.positive?
          end
        end

        # Record that a reconciliation-adopted, still-waiting marker found no eligible agent this
        # pass, KEEPING the marker for a later trigger. Counts the conversation as no_eligible_agent
        # exactly once (idempotent across repeated no-agent passes) via the persisted
        # reconciliation_outcome, and the conditional update is itself single-shot under concurrency.
        #
        # ATOMIC: the marker's outcome transition and the ledger counter transition run in ONE
        # transaction. A crash/raise between them would otherwise permanently undercount — the marker
        # would read NO_ELIGIBLE_AGENT while the run counter never incremented, and every later pass
        # would return early seeing no transition. Wrapping both means a failed ledger update rolls
        # the marker's outcome back so the next pass re-attempts the whole transition cleanly.
        #
        # RACE-SAFE: as with resolve_and_record, the marker is locked SELECT ... FOR UPDATE and its
        # generation/previous disposition are re-read INSIDE the transaction after the lock, so a
        # racing resolve/record cannot slip a state change between the read and the conditional write.
        def self.record_waiting(conversation_id)
          transaction do
            marker = lock.find_by(conversation_id: conversation_id)
            next if marker.nil? || marker.reconciliation_generation.blank?

            previous = marker.reconciliation_outcome
            next if previous == ReconciliationRun::NO_ELIGIBLE_AGENT

            # rubocop:disable Rails/SkipsModelValidations
            updated = where(conversation_id: conversation_id, reconciliation_outcome: previous)
                      .update_all(reconciliation_outcome: ReconciliationRun::NO_ELIGIBLE_AGENT, updated_at: Time.current)
            # rubocop:enable Rails/SkipsModelValidations
            ReconciliationRun.record_outcome(marker.reconciliation_generation, ReconciliationRun::NO_ELIGIBLE_AGENT, previous) if updated.positive?
          end
        end

        private

        # See the after_destroy comment above. Atomic within the destroy transaction; single-shot
        # (the marker row is gone once destroy commits, so it cannot fire twice for one occurrence).
        def wijaya_record_terminal_disposition
          return if reconciliation_generation.blank?

          ReconciliationRun.record_outcome(
            reconciliation_generation, ReconciliationRun::DROPPED, reconciliation_outcome
          )
        end
      end
    end
  end
end
