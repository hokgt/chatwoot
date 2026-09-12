# frozen_string_literal: true

# Automatic, one-time historical reconciliation for the deferred auto-assignment battery.
#
# It scans ONLY the durable structured provenance rows (never all unassigned conversations),
# in bounded batches, and for each conversation that is STRUCTURALLY PROVEN to have been assigned
# to a human agent who was subsequently deleted, adopts it into the EXACT existing live pipeline
# through the provenance-backed Registrar entrypoint (marker -> ProcessInboxJob -> InboxProcessor
# -> native AgentAssignmentService -> conversation.update! -> existing ERP owner-sync callback).
# It NEVER sets assignee_id directly and NEVER introduces a second assignment engine.
#
# Idempotent + non-recurring: guarded by the ReconciliationRun ledger (unique generation) so a
# completed generation is never re-scanned, and every examined provenance row is stamped
# reconciled_at so it is processed at most once across retries. A retried job for the same
# generation resumes safely.
#
# Fail-closed proof (requirement: any uncertainty => skipped/ambiguous, never registered):
#   AMBIGUOUS (never registered) — no structural proof of a deleted-agent orphan:
#     * the conversation no longer exists;
#     * the conversation's account does not match the provenance account (cross-account safety);
#     * the provenance event is not a recorded agent deletion;
#     * the conversation was created at/after the reconciliation cutoff;
#     * the prior assignee is STILL an account member (not actually deleted / re-created).
#   SKIPPED (proven orphan but not currently actionable, left to existing behavior):
#     * it already carries a marker (the live pipeline already owns it);
#     * it is not currently Eligibility.deferrable? (resolved/snoozed/pending, already manually or
#       bot-assigned, team auto-assign off, moved to V2, inbox gone).
#   REGISTERED — proven orphan AND currently deferrable: handed to the shared pipeline.
#
# Pre-provenance legacy cases (conversations unassigned by a deletion that happened BEFORE this
# battery recorded provenance) have NO provenance row and are therefore invisible here — they are
# never guessed from free-text activity. See BACKFILL.md for why they cannot be recovered
# automatically without an external authoritative source.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module Reconciler
        module_function

        BATCH_SIZE = 200

        # Runs (or resumes) the reconciliation for +generation+. Returns the run ledger row.
        def run(generation:)
          run_row = start_run(generation)
          return run_row if run_row.completed?

          cutoff = run_row.cutoff_at
          counts = Hash.new(0)
          scope(cutoff).find_in_batches(batch_size: BATCH_SIZE) do |batch|
            process_batch(batch, cutoff, counts)
          end
          finalize(run_row, counts)
        end

        # find_or_create keyed on the unique generation: a re-enqueue/retry for the same
        # generation reuses the existing run (resume) instead of starting a second engine.
        def start_run(generation)
          now = Time.current
          ReconciliationRun.find_or_create_by!(generation: generation) do |row|
            row.status = ReconciliationRun::RUNNING
            row.started_at = now
            row.cutoff_at = now
          end
        end

        # Only historical, not-yet-reconciled provenance rows (event strictly before the cutoff).
        def scope(cutoff)
          DeletionProvenance.unreconciled.where(event_at: ...cutoff).order(:id)
        end

        def process_batch(batch, cutoff, counts)
          registerable = Hash.new { |hash, key| hash[key] = [] }
          batch.each do |row|
            counts[:scanned] += 1
            category = classify(row, cutoff)
            counts[category] += 1
            registerable[row.account_id] << row.conversation_id if category == :registered
          end
          # Every examined row is stamped reconciled so it is never rescanned (one-time semantics).
          mark_reconciled(batch)
          registerable.each { |account_id, ids| Registrar.register_unassigned_from_provenance(account_id, ids) }
        end

        # :registered | :skipped | :ambiguous — fail-closed (see module doc).
        def classify(row, cutoff)
          return :ambiguous unless proven_orphan?(row, cutoff)
          return :skipped if Marker.exists?(conversation_id: row.conversation_id)
          return :skipped unless Eligibility.deferrable?(row.conversation)

          :registered
        end

        # Structural proof (fail-closed) that this provenance row identifies a conversation whose
        # human assignee was subsequently deleted: the conversation exists, belongs to the same
        # account (cross-account safety), the event is a recorded agent deletion, the conversation
        # predates the cutoff, and the prior agent is no longer a member of this account.
        def proven_orphan?(row, cutoff)
          conversation = row.conversation
          return false if conversation.nil?
          return false unless conversation.account_id == row.account_id
          return false unless row.event == DeletionProvenance::AGENT_DELETION
          return false unless conversation.created_at < cutoff

          deletion_confirmed?(row)
        end

        # Structural proof that the prior HUMAN assignee was subsequently removed: prior_assignee_id
        # was captured from assignee_id (always a User, never an agent bot), and the agent must no
        # longer be a member of this account. If they are still a member, this is not a deleted-agent
        # orphan and we refuse to act (ambiguous).
        def deletion_confirmed?(row)
          !AccountUser.exists?(account_id: row.account_id, user_id: row.prior_assignee_id)
        end

        def mark_reconciled(batch)
          # rubocop:disable Rails/SkipsModelValidations
          DeletionProvenance.where(id: batch.map(&:id)).update_all(reconciled_at: Time.current)
          # rubocop:enable Rails/SkipsModelValidations
        end

        # Accurate, content-free run metrics. Assignment OUTCOME (assigned / no eligible agent /
        # marker retained) is produced asynchronously by the shared InboxProcessor, which logs it
        # per marker — this run only owns what it can truthfully count: scanned / registered /
        # skipped / ambiguous.
        def finalize(run_row, counts)
          run_row.update!(
            status: ReconciliationRun::COMPLETED,
            finished_at: Time.current,
            scanned: counts[:scanned],
            registered: counts[:registered],
            skipped: counts[:skipped],
            ambiguous: counts[:ambiguous]
          )
          Rails.logger.info(
            "[Wijaya] deferred reconciliation generation=#{run_row.generation} " \
            "scanned=#{counts[:scanned]} registered=#{counts[:registered]} " \
            "skipped=#{counts[:skipped]} ambiguous=#{counts[:ambiguous]}"
          )
          run_row
        end
      end
    end
  end
end
