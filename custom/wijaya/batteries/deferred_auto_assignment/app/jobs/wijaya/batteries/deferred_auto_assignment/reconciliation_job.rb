# frozen_string_literal: true

# Background worker for automatic reconciliation, RETAINED for legacy / manual / already-queued
# compatibility (an operator invoking a one-off resume, or an old job still sitting on the :low queue
# from before this change). It is NOT enqueued by a migration and is NO LONGER enqueued by the
# recurring coordinator: the RecoveryDrainerJob now selects at most one persisted run intent per tick
# and runs the Reconciler INLINE under its global advisory lock (see RecoveryDrainerJob), so recovery
# never fans out onto a second Redis queue with its own retry tree. The one-time historical
# reconciliation remains a DURABLE persisted run intent (a 'running' wijaya_deferred_reconciliation_
# runs row the migration INSERTs, with a full-history cutoff) that the coordinator resumes inline.
# This job simply delegates to the same Reconciler, which is guarded by the ReconciliationRun ledger
# (unique generation) so a normal ActiveJob retry or a duplicate enqueue resumes the same run rather
# than starting a second scan. It scans only durable provenance rows in bounded batches; it never
# scans all unassigned conversations and never assigns directly.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      class ReconciliationJob < ApplicationJob
        queue_as :low

        # Bounded retry, consistent with the app's job conventions (retry_on wait:/attempts:, e.g.
        # Captain::Documents::PerformSyncJob) — NOT an unbounded custom loop. On a batch failure the
        # Reconciler leaves the run RUNNING with its already-committed batches intact and re-raises;
        # each retry RESUMES the same generation from the still-unreconciled rows (ledger-guarded),
        # and the run's failed/retries counters record the attempt history truthfully. After the
        # attempts are exhausted the job is dropped by ActiveJob and the run stays RUNNING, safe to
        # re-enqueue later without rescanning completed batches.
        retry_on StandardError, wait: :polynomially_longer, attempts: 5

        # +cutoff+ (an optional Time; nil for the one-time migration run => full history) bounds the
        # provenance scan; the recurring RecoveryDrainerJob passes now - SAFETY_AGE. It is persisted
        # as the run's cutoff_at on first create, so a retry/resume reuses the original bound.
        def perform(generation:, cutoff: nil)
          Reconciler.run(generation: generation, cutoff: cutoff)
        end
      end
    end
  end
end
