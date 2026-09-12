# frozen_string_literal: true

require 'zlib'

# Automatic, one-time historical reconciliation for the deferred auto-assignment battery.
#
# It scans ONLY the durable structured provenance rows (never all unassigned conversations),
# in bounded batches, and for each conversation that is STRUCTURALLY PROVEN to have been assigned
# to a human agent who was subsequently deleted, adopts it into the EXACT existing live pipeline
# through the provenance-backed Registrar entrypoint (marker -> ProcessInboxJob -> InboxProcessor
# -> native AgentAssignmentService -> conversation.update! -> existing ERP owner-sync callback).
# It NEVER sets assignee_id directly and NEVER introduces a second assignment engine.
#
# Idempotent + non-recurring + resumable: guarded by the ReconciliationRun ledger (unique
# generation) so a completed generation is never re-scanned. Each batch is claimed with FOR UPDATE
# SKIP LOCKED and, in ONE transaction, classified, registered, stamped reconciled_at, and its
# counters added to the run — so a row is marked (and counted) at most once, only after its
# disposition has committed. A failed batch rolls back wholesale (row left unreconciled, counters
# untouched) and a retried/duplicate job for the same generation RESUMES from the remaining
# unreconciled rows without losing or double-counting work.
#
# Single-run serialization + durable dispatch (correctness): the entire scan + dispatch + finalize
# runs under a PostgreSQL SESSION advisory lock scoped to the generation, so at most ONE job for a
# generation is ever inside it. FOR UPDATE SKIP LOCKED then only ever guards against an unexpected
# stray process (defense in depth), never the normal path. A duplicate that cannot take the lock
# returns the still-RUNNING ledger without scanning, dispatching, or finalizing — it can NEVER mark
# a run completed while another worker still owns (and may roll back) the tail of the scan. The
# coalesced ProcessInboxJob is NOT enqueued per batch; instead, after all batches are scanned, the
# reconciliation-stamped markers themselves are the durable outbox and every still-present one for
# the generation is (re-)dispatched, then the run is finalized. A crash/raise between a batch commit
# and dispatch therefore strands nothing: a retry re-dispatches every still-present generation
# marker, relying on the existing in-flight coalescing + InboxProcessor idempotency.
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

        # A fixed classid that namespaces THIS battery's PostgreSQL advisory locks (the two-int
        # pg_advisory_lock form), so a generation lock can never collide with an unrelated advisory
        # lock elsewhere in the app. Arbitrary constant ("WIJA"), well within a signed int4.
        ADVISORY_NAMESPACE = 0x77494a41

        # Runs (or resumes) the reconciliation for +generation+. Returns the run ledger row.
        #
        # Serialization: the whole scan + dispatch + finalize executes under a session advisory lock
        # scoped to the generation, so only ONE job runs it at a time. A duplicate/concurrent job that
        # cannot take the lock returns the still-RUNNING ledger WITHOUT finalizing (see module doc);
        # it never completes a run another worker still owns. The lock auto-releases if the owner's DB
        # session dies, so a later re-enqueue safely resumes.
        def run(generation:)
          run_row, resumed = start_run(generation)
          return run_row if run_row.completed?
          # Could not serialize: another worker owns this generation. Do NOT finalize — return the
          # current (running) ledger; the owner (or a later retry, once the lock frees) completes it.
          return run_row.reload unless acquire_generation_lock(generation)

          begin
            reconcile_locked(run_row, resumed)
          ensure
            release_generation_lock(generation)
          end
        end

        # Body executed while holding the generation advisory lock. Re-reads the ledger first so a run
        # the previous owner completed while we were locked out is a no-op here too.
        #
        # Retry / resume safety: rows are NOT stamped reconciled and counters are NOT bumped until
        # their registration disposition has committed durably (see process_next_batch). If a batch
        # raises (DB / Registrar failure) the whole batch transaction rolls back, the run is left
        # RUNNING, failed is incremented, and the error propagates so ReconciliationJob's bounded
        # retry_on re-enters here and RESUMES from the still-unreconciled rows — every row is processed
        # exactly once and no counter is lost or double-counted across attempts. dispatch (the durable
        # outbox enqueue) is the LAST step before finalize, so a run is completed only after every
        # adopted inbox has been (re-)dispatched.
        def reconcile_locked(run_row, resumed)
          run_row.reload
          return run_row if run_row.completed?

          # rubocop:disable Rails/SkipsModelValidations
          ReconciliationRun.increment_counter(:retries, run_row.id) if resumed
          begin
            process_all(run_row, run_row.cutoff_at)
            dispatch(run_row)
          rescue StandardError
            ReconciliationRun.increment_counter(:failed, run_row.id)
            raise
          end
          # rubocop:enable Rails/SkipsModelValidations
          finalize(run_row)
        end

        # Non-blocking acquire of the generation's session advisory lock on the current connection.
        # Returns true iff THIS session now holds it. Non-blocking (pg_try_advisory_lock) so a
        # duplicate job never parks a worker for the whole run; it simply defers to the owner and
        # returns. A crashed owner's lock is released automatically when its DB session ends.
        def acquire_generation_lock(generation)
          ActiveRecord::Base.connection.select_value(
            "SELECT pg_try_advisory_lock(#{ADVISORY_NAMESPACE}, #{advisory_key(generation)})"
          )
        end

        # Releases the generation's session advisory lock on the current connection. Always run in an
        # ensure; a safe no-op if this session does not hold it.
        def release_generation_lock(generation)
          ActiveRecord::Base.connection.select_value(
            "SELECT pg_advisory_unlock(#{ADVISORY_NAMESPACE}, #{advisory_key(generation)})"
          )
        end

        # Stable signed 32-bit key derived from the generation string (advisory keys are int4 in the
        # two-argument form). CRC32 is deterministic and process-independent; shifting into signed
        # range keeps it a valid int4.
        def advisory_key(generation)
          Zlib.crc32(generation.to_s) - (2**31)
        end

        # find_or_create keyed on the unique generation so a duplicate/retried job resumes the SAME
        # run rather than starting a second engine (find_or_create_by! also absorbs the
        # concurrent-create race — the loser re-finds the winner's row). previously_new_record?
        # distinguishes a fresh start (resumed=false) from a resume of an existing run (resumed=true).
        def start_run(generation)
          now = Time.current
          run = ReconciliationRun.find_or_create_by!(generation: generation) do |row|
            row.status = ReconciliationRun::RUNNING
            row.started_at = now
            row.cutoff_at = now
          end
          [run, !run.previously_new_record?]
        end

        # Only historical, not-yet-reconciled provenance rows (event strictly before the cutoff).
        def scope(cutoff)
          DeletionProvenance.unreconciled.where(event_at: ...cutoff).order(:id)
        end

        # The claim query for one batch: FOR UPDATE SKIP LOCKED (the same primitive the native
        # AutoAssignment::AssignmentService uses). The generation advisory lock already guarantees a
        # single runner, so this is defense in depth: even if a stray process bypassed the advisory
        # lock, it would lock disjoint rows and never double-process the same provenance row rather
        # than blocking.
        def batch_scope(cutoff)
          scope(cutoff).limit(BATCH_SIZE).lock('FOR UPDATE SKIP LOCKED')
        end

        def process_all(run_row, cutoff)
          loop { break unless process_next_batch(run_row, cutoff) }
        end

        # Claim + classify + register + stamp + count for ONE batch inside a single transaction,
        # holding the FOR UPDATE SKIP LOCKED row locks for its whole lifetime. Returns true while
        # rows remain. Marker creation (Registrar) happens inside this transaction so it is atomic
        # with the reconciled stamp and the counter bump; a rolled-back batch leaves no phantom
        # marker and no counter drift. This method performs NO side effect outside its transaction —
        # the coalesced per-inbox ProcessInboxJob is enqueued later by dispatch (the durable outbox),
        # so a crash between a batch commit and the enqueue can never strand a marker without a job.
        def process_next_batch(run_row, cutoff)
          had_rows = false
          ActiveRecord::Base.transaction do
            batch = batch_scope(cutoff).to_a
            if batch.present?
              had_rows = true
              process_batch(batch, cutoff, run_row)
            end
          end
          had_rows
        end

        def process_batch(batch, cutoff, run_row)
          counts, registerable = classify_batch(batch, cutoff)
          adopted = register(registerable, run_row.generation)
          # "registered" is the ACTUAL adopted count from the Registrar's re-check, not the
          # classification prediction. Candidates the Registrar declined (raced: marked/assigned in
          # between) fall back to skipped so scanned == identified + ambiguous and
          # identified == registered + skipped stay exact.
          candidates = registerable.values.sum(&:size)
          counts[:registered] = adopted
          counts[:skipped] += candidates - adopted
          # Stamp + count only AFTER registration succeeded, atomically within this transaction.
          mark_reconciled(batch)
          bump_counters!(run_row, counts)
        end

        def classify_batch(batch, cutoff)
          counts = Hash.new(0)
          registerable = Hash.new { |hash, key| hash[key] = [] }
          batch.each do |row|
            counts[:scanned] += 1
            category = classify(row, cutoff)
            counts[:identified] += 1 unless category == :ambiguous
            if category == :registered
              registerable[row.account_id] << row.conversation_id
            else
              counts[category] += 1
            end
          end
          [counts, registerable]
        end

        # Register each account's candidate ids through the shared provenance entry point, returning
        # the ACTUAL number of markers adopted (the Registrar re-checks each candidate). The inboxes
        # to process are NOT collected here — dispatch derives them durably from the stamped markers.
        def register(registerable, generation)
          registerable.sum do |account_id, conversation_ids|
            Registrar.register_unassigned_from_provenance(account_id, conversation_ids, generation: generation)[:adopted]
          end
        end

        # Durable outbox dispatch (runs after ALL scan batches, inside the generation lock). The
        # reconciliation-stamped markers ARE the outbox: every still-present marker for this
        # generation is a conversation that was adopted but not yet resolved, so we (re-)enqueue a
        # coalesced ProcessInboxJob for each distinct inbox. This closes the durability gap where a
        # crash/raise AFTER a batch committed but BEFORE its enqueue could strand a marker with no
        # job: a resumed run re-dispatches every still-present generation marker, and the in-flight
        # coalescing + InboxProcessor idempotency make repeated dispatch harmless. It is the LAST
        # step before finalize, so a run is completed only once every adopted inbox has been
        # (re-)dispatched; a raise here leaves the run RUNNING for the next retry.
        def dispatch(run_row)
          Marker.where(reconciliation_generation: run_row.generation).distinct.pluck(:inbox_id).each do |inbox_id|
            ProcessInboxJob.enqueue_for_inbox(inbox_id)
          end
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

        # Cumulative, idempotent per-batch counter persistence: a single atomic UPDATE that adds
        # this batch's classification/registration counts to the run row, committed inside the same
        # transaction as mark_reconciled. Because a batch is stamped reconciled iff its counters are
        # bumped, a resumed run re-scans only still-unreconciled rows, so totals stay exact across
        # any number of failures/retries — never lost, never double-counted.
        def bump_counters!(run_row, counts)
          assignments = [
            'scanned = scanned + ?, identified = identified + ?, registered = registered + ?, ' \
            'skipped = skipped + ?, ambiguous = ambiguous + ?, updated_at = ?',
            counts[:scanned], counts[:identified], counts[:registered],
            counts[:skipped], counts[:ambiguous], Time.current
          ]
          # rubocop:disable Rails/SkipsModelValidations
          ReconciliationRun.where(id: run_row.id).update_all(assignments)
          # rubocop:enable Rails/SkipsModelValidations
        end

        # Marks the run COMPLETED and logs the persisted totals. COMPLETED means only that the scan +
        # durable dispatch have been accepted: the scan-time counters (scanned / identified /
        # registered / skipped / ambiguous) are final here, but the async dispositions (assigned /
        # no_eligible_agent / dropped) keep TRANSITIONING afterwards as the shared InboxProcessor
        # resolves each registered marker, and reflect the latest unique disposition per conversation
        # at read time. failed / retries reflect this generation's attempt history.
        def finalize(run_row)
          run_row.reload
          run_row.update!(status: ReconciliationRun::COMPLETED, finished_at: Time.current)
          Rails.logger.info(
            "[Wijaya] deferred reconciliation generation=#{run_row.generation} " \
            "scanned=#{run_row.scanned} identified=#{run_row.identified} registered=#{run_row.registered} " \
            "skipped=#{run_row.skipped} ambiguous=#{run_row.ambiguous} retries=#{run_row.retries} failed=#{run_row.failed}"
          )
          run_row
        end
      end
    end
  end
end
