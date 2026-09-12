# frozen_string_literal: true

# Persisted run/cutoff/completion ledger for the one-time automatic historical reconciliation.
# Exactly one row per generation (unique) records that the reconciliation for that generation is
# running or has completed, plus the cutoff timestamp and accurate per-run counters. It makes the
# migration-triggered ReconciliationJob idempotent and non-recurring: a completed generation is
# never re-scanned, and a retried/re-enqueued job for the same generation resumes safely rather
# than starting a second engine.
#
# Nested (not compact) to match the sibling battery files.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      class ReconciliationRun < ApplicationRecord
        self.table_name = 'wijaya_deferred_reconciliation_runs'

        RUNNING = 'running'
        COMPLETED = 'completed'

        validates :generation, presence: true, uniqueness: true

        def completed?
          status == COMPLETED
        end
      end
    end
  end
end
