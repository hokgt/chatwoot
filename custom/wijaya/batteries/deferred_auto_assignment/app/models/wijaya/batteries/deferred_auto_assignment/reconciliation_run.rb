# frozen_string_literal: true

# Persisted run/cutoff/completion ledger for the one-time automatic historical reconciliation.
# Exactly one row per generation (unique) records that the reconciliation for that generation is
# running or has completed, plus the cutoff timestamp and the full set of REQUIRED, truthful
# counters. It makes reconciliation idempotent and non-recurring: a completed generation is never
# re-scanned, and a later tick (the RecoveryDrainerJob coordinator resuming an incomplete run inline,
# or a legacy/manual ReconciliationJob) for the same generation resumes safely rather than starting a
# second engine.
#
# Counter semantics (all persisted incrementally + idempotently, never recomputed):
#   scanned            provenance rows examined by the scan (each stamped reconciled exactly once)
#   identified         of those, the ones structurally PROVEN to be deleted-agent orphans
#                      (registered + skipped); the complement is ambiguous
#   registered         orphans a marker was ACTUALLY adopted for by this reconciliation (post
#                      Registrar re-check; a race that claimed the row is NOT counted here)
#   skipped            proven orphans left to existing behavior (already marked / not deferrable /
#                      raced between classification and registration)
#   ambiguous          rows without structural proof (never touched)
#   assigned /         the LATEST, unique async disposition of each registered marker as the shared
#   no_eligible_agent /  InboxProcessor resolves it: assigned by the native selector, still waiting
#   dropped              for an agent, or dropped (became ineligible / claimed elsewhere). A marker
#                      counts toward exactly one of these at a time; a repeated no-agent pass is not
#                      re-counted, and a later assign/drop transitions the count (see record_outcome).
#   failed / retries   failed run attempts and resumes (job retries) for this generation.
#
# Nested (not compact) to match the sibling battery files.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      class ReconciliationRun < ApplicationRecord
        self.table_name = 'wijaya_deferred_reconciliation_runs'

        RUNNING = 'running'
        COMPLETED = 'completed'

        # The three terminal/transient async dispositions the InboxProcessor records per marker.
        ASSIGNED = 'assigned'
        NO_ELIGIBLE_AGENT = 'no_eligible_agent'
        DROPPED = 'dropped'
        # Whitelist mapping a disposition to its counter column — the ONLY values interpolated into
        # the atomic UPDATE below, so record_outcome can never be driven to an arbitrary column.
        OUTCOME_COLUMNS = { ASSIGNED => 'assigned', NO_ELIGIBLE_AGENT => 'no_eligible_agent', DROPPED => 'dropped' }.freeze

        validates :generation, presence: true, uniqueness: true

        # Runs that have NOT yet reached completion — durable work intents the RecoveryDrainerJob
        # coordinator adopts each tick and runs INLINE (via Reconciler.run under the global advisory
        # lock, never a re-enqueue) until they truthfully complete. Covers the one-time reconciliation
        # intent the migration persists (started_at NULL) and any run left 'running' by an earlier
        # failed tick, so no run intent is ever silently stranded.
        scope :incomplete, -> { where(status: RUNNING) }

        def completed?
          status == COMPLETED
        end

        # Atomically move one registered marker from its +previous+ disposition bucket to +bucket+
        # for +generation+, in a single UPDATE: increment the new bucket and (when transitioning
        # away from an earlier recorded bucket) decrement the old one, floored at zero. Idempotent
        # by construction — the caller only invokes this on a real transition (bucket != previous),
        # guarded by the marker's persisted reconciliation_outcome, so a repeated no-agent pass or a
        # duplicate resolve records nothing. A no-op when the marker was not reconciliation-owned
        # (generation blank) or the bucket is unknown, so the shared pipeline stays untouched for
        # ordinary markers.
        def self.record_outcome(generation, bucket, previous)
          return if generation.blank?

          increment_column = OUTCOME_COLUMNS[bucket]
          return if increment_column.nil? || bucket == previous

          assignments = ["#{increment_column} = #{increment_column} + 1"]
          decrement_column = OUTCOME_COLUMNS[previous]
          assignments << "#{decrement_column} = GREATEST(#{decrement_column} - 1, 0)" if decrement_column
          # rubocop:disable Rails/SkipsModelValidations
          where(generation: generation).update_all("#{assignments.join(', ')}, updated_at = NOW()")
          # rubocop:enable Rails/SkipsModelValidations
        end
      end
    end
  end
end
