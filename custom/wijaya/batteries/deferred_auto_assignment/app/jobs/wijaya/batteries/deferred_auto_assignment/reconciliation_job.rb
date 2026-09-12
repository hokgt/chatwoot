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

        def perform(generation:)
          Reconciler.run(generation: generation)
        end
      end
    end
  end
end
