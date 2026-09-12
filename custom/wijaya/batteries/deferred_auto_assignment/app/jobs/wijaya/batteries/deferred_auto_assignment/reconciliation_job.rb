# frozen_string_literal: true

# One-time background worker for the automatic historical reconciliation. Enqueued exactly once
# by the EnqueueDeferredAssignmentReconciliation migration (mirroring the established
# EnqueueValidateOpenaiHooksJob convention), it delegates to the Reconciler, which is guarded by
# the ReconciliationRun ledger (unique generation) so a normal ActiveJob retry or a duplicate
# enqueue resumes the same run rather than starting a second scan. It scans only durable
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

        def perform(generation:)
          Reconciler.run(generation: generation)
        end
      end
    end
  end
end
