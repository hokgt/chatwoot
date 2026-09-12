# frozen_string_literal: true

# Background worker for automatic reconciliation. It is NOT enqueued by a migration: the one-time
# historical reconciliation is a DURABLE persisted run intent (a 'running' wijaya_deferred_
# reconciliation_runs row the migration INSERTs, with a full-history cutoff), and the recurring
# RecoveryDrainerJob coordinator is the sole enqueuer — each tick it (re-)enqueues at most one
# incomplete run until it truthfully completes, and separately opens a fresh generation + short
# safety-age cutoff to drain crash-gap provenance the one-time run's fixed cutoff can never reach.
# Relying on the durable intent + coordinator (rather than a fragile perform_later inside the
# migration) survives Redis downtime and an old worker consuming the job against an incomplete
# schema. It delegates to the Reconciler, which
# is guarded by the ReconciliationRun ledger (unique generation) so a normal ActiveJob retry or a
# duplicate enqueue resumes the same run rather than starting a second scan. It scans only durable
# provenance rows in bounded batches; it never scans all unassigned conversations and never
# assigns directly.
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
