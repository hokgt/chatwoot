# frozen_string_literal: true

# Automatic reconciliation for the deferred auto-assignment battery.
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
# Two callers reach this: the one-time migration run (a fixed historical cutoff, generation =
# the enqueue migration's version) and the recurring RecoveryDrainerJob coordinator, which each tick
# resumes the oldest incomplete run inline (including that persisted migration intent) or opens one
# fresh generation with a short safety-age cutoff. The drainer is the durable-outbox/crash-gap
# fallback for provenance recorded AFTER the migration ran — see RecoveryDrainerJob and BACKFILL.md.
# The normal
# Agents::DestroyJob -> Registrar bridge remains the PRIMARY future deletion path, unchanged.
#
# Single-run serialization + durable dispatch (correctness): the entire scan + dispatch + finalize
# runs under a single GLOBAL PostgreSQL SESSION advisory lock (a fixed key, NOT scoped to the
# generation), so at most ONE reconciliation of ANY generation is ever inside it — the migration
# run and every drainer run are strictly serialized and can never race each other's run rows. FOR
# UPDATE SKIP LOCKED then only ever guards against an unexpected stray process (defense in depth),
# never the normal path. A caller that cannot take the lock RAISES (LockContention) instead of
# returning a successful no-op, so its generation is eventually processed once the lock frees rather
# than stranding its run row permanently 'running' (which a silent running return would do — nothing
# else would retry it): the RecoveryDrainerJob coordinator swallows it and the next hourly tick
# resumes the same incomplete run inline, and the legacy ReconciliationJob's bounded retry_on
# re-enqueues it. It
# can NEVER mark a run completed while another worker still owns (and may roll back) the tail of the
# scan. The coalesced ProcessInboxJob is NOT enqueued per batch; instead, after all batches are scanned, the
# reconciliation-stamped markers themselves are the durable outbox and every still-present one for
# the generation is (re-)dispatched, then the run is finalized. A crash/raise between a batch commit
# and dispatch therefore strands nothing: a retry re-dispatches every still-present generation
# marker, relying on the existing in-flight coalescing + InboxProcessor idempotency. That per-batch
# dispatch is BEST-EFFORT (a stale in-flight key from a crashed worker coalesces it away and later
# expires unconsumed), so finalizing right after it does NOT itself guarantee a worker ran — the
# marker plus the hourly RecoveryDrainerJob marker-outbox drain (which redispatches every
# still-present marker every tick, independent of run/provenance state) is the durable guarantee.
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
        # pg_advisory_lock form), so the reconciliation lock can never collide with an unrelated
        # advisory lock elsewhere in the app. Arbitrary constant ("WIJA"), well within a signed int4.
        ADVISORY_NAMESPACE = 0x77494a41

        # A single fixed key (in the battery's advisory namespace) shared by ALL generations, making
        # the lock GLOBAL to the reconciliation feature rather than per-generation: at most one
        # reconciliation run of any generation executes at a time (see module doc, requirement: two
        # different generations must never race/strand each other's 'running' run rows).
        GLOBAL_LOCK_KEY = 0

        # Raised when the global reconciliation lock is already held by another run. It is a
        # StandardError so ReconciliationJob's retry_on re-enqueues, giving safe eventual processing
        # instead of a successful no-op that would leave this run row permanently 'running'.
        class LockContention < StandardError; end

        # Runs (or resumes) the reconciliation for +generation+. Returns the run ledger row.
        # +cutoff+ is the exclusive upper bound on provenance event_at (and conversation created_at):
        # the one-time migration run passes nil (=> now, all history); the recurring RecoveryDrainerJob
        # passes now - SAFETY_AGE so it only ever picks up crash-gap stragglers, never rows the live
        # bridge is still handling. It is persisted as cutoff_at on first create, so a resume reuses it.
        #
        # Serialization: the whole scan + dispatch + finalize executes under a GLOBAL session advisory
        # lock, so only ONE reconciliation runs at a time. A job that cannot take the lock RAISES
        # LockContention (see module doc) so retry_on re-enqueues it — it never returns a successful
        # no-op that would strand its run row 'running'. The lock auto-releases if the owner's DB
        # session dies, so a later re-enqueue safely resumes.
        def run(generation:, cutoff: nil)
          run_row, resumed = start_run(generation, cutoff)
          return run_row if run_row.completed?
          # Could not serialize: another generation's run owns the global lock. RAISE so the bounded
          # retry_on re-enqueues this generation; it is processed once the lock frees. Never a silent
          # no-op — that would leave this run row permanently 'running' with nothing to retry it.
          raise LockContention, "reconciliation lock busy (generation=#{generation})" unless acquire_global_lock

          begin
            reconcile_locked(run_row, resumed)
          ensure
            release_global_lock
          end
        end

        # Body executed while holding the global advisory lock. Re-reads the ledger first so a run
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

        # Non-blocking acquire of the GLOBAL reconciliation session advisory lock on the current
        # connection. Returns true iff THIS session now holds it. Non-blocking (pg_try_advisory_lock)
        # so a contending job never parks a worker for the whole run; it defers (raises) to the owner.
        # A crashed owner's lock is released automatically when its DB session ends.
        def acquire_global_lock
          ActiveRecord::Base.connection.select_value(
            "SELECT pg_try_advisory_lock(#{ADVISORY_NAMESPACE}, #{GLOBAL_LOCK_KEY})"
          )
        end

        # Releases the GLOBAL reconciliation session advisory lock on the current connection. Always
        # run in an ensure; a safe no-op if this session does not hold it.
        def release_global_lock
          ActiveRecord::Base.connection.select_value(
            "SELECT pg_advisory_unlock(#{ADVISORY_NAMESPACE}, #{GLOBAL_LOCK_KEY})"
          )
        end

        # find_or_create keyed on the unique generation so a duplicate/retried job resumes the SAME
        # run rather than starting a second engine (find_or_create_by! also absorbs the
        # concurrent-create race — the loser re-finds the winner's row). cutoff_at is fixed at first
        # create (nil => now), so a resume keeps the original bound.
        #
        # resumed is derived from started_at, NOT previously_new_record?, so a DURABLE run intent
        # persisted ahead of time by the one-time reconciliation migration (a row created with
        # started_at NULL, executed later by the RecoveryDrainerJob coordinator) counts its FIRST
        # execution as a fresh start (resumed=false, retries stays 0), and only a genuine
        # re-execution after it has already started counts as a retry.
        def start_run(generation, cutoff)
          now = Time.current
          run = ReconciliationRun.find_or_create_by!(generation: generation) do |row|
            row.status = ReconciliationRun::RUNNING
            row.cutoff_at = cutoff || now
          end
          resumed = run.started_at.present?
          run.update!(started_at: now) if run.started_at.nil? && !run.completed?
          [run, resumed]
        end

        # Only historical, not-yet-reconciled provenance rows (event strictly before the cutoff).
        def scope(cutoff)
          DeletionProvenance.unreconciled.where(event_at: ...cutoff).order(:id)
        end

        # The claim query for one batch: FOR UPDATE SKIP LOCKED (the same primitive the native
        # AutoAssignment::AssignmentService uses). The global advisory lock already guarantees a
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

        # Best-effort outbox dispatch (runs after ALL scan batches, inside the global lock). The
        # reconciliation-stamped markers ARE the durable outbox: every still-present marker for this
        # generation is a conversation that was adopted but not yet resolved, so we (re-)enqueue a
        # coalesced ProcessInboxJob for each distinct inbox. A resumed run re-dispatches every
        # still-present generation marker, and the in-flight coalescing + InboxProcessor idempotency
        # make repeated dispatch harmless.
        #
        # It is intentionally acceptable to finalize the run right after this: enqueue_for_inbox is
        # best-effort (a stale in-flight key from a crashed worker coalesces the dispatch away, and
        # both keys later expire with no worker having consumed them), so this step alone does NOT
        # guarantee a worker ran. The DURABLE guarantee is the marker itself plus the hourly
        # RecoveryDrainerJob marker-outbox drain, which redispatches every still-present marker each
        # tick regardless of run/provenance state (see RecoveryDrainerJob#drain_marker_outbox). Once
        # this run is completed its provenance is reconciled and the crash-gap branch no longer sees
        # it, so that always-on marker drain — not a re-dispatch by this finalized run — is what
        # eventually drives a coalesced-away marker to assignment. A raise here still leaves the run
        # RUNNING for the next retry.
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
