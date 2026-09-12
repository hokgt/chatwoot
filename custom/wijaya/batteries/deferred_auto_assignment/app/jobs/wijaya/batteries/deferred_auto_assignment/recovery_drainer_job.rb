# frozen_string_literal: true

# Low-frequency RECOVERY DRAINER + run-intent COORDINATOR for the deferred auto-assignment battery.
#
# This job IS the recovery unit: it is itself a single hourly scheduled cron occurrence (see
# config/schedule.yml), and each tick selects AT MOST ONE persisted run intent and processes it
# INLINE by calling Reconciler.run directly, under the Reconciler's existing GLOBAL advisory lock.
# It does NOT hand off to a second Redis queue: it never calls ReconciliationJob.perform_later or
# perform_now. That handoff was the release blocker — while the :low queue was delayed/down each tick
# would enqueue another ReconciliationJob for the same work, accumulating duplicates each with its
# own retry_on tree, and a fresh generation could be enqueued before its run row was atomically
# claimed. Running inline collapses recovery to exactly one queued unit per tick (this cron
# occurrence) with no independent downstream retry tree.
#
# One intent per tick (BOUNDED — the amplification guard):
#   1. If ANY ReconciliationRun is incomplete, adopt the OLDEST and process it inline with its OWN
#      persisted generation/cutoff, creating NO new generation. This is how the ONE-TIME historical
#      reconciliation runs safely: its migration persists a 'running' run intent (no fragile Redis
#      perform_later) and this resumes it under new code with the full schema, so Redis downtime or an
#      old worker consuming a job against an incomplete schema can no longer lose it. It also recovers
#      any run left 'running' by a crash or an expected failure on a prior tick.
#   2. ONLY when every intent has truthfully completed does a tick open recovery work: if a genuine
#      crash-gap straggler exists it DURABLY find-or-creates exactly ONE fresh recovery run intent
#      (persisted before any processing) and reconciles THAT run inline. So a persistent registrar /
#      DB / lock failure can never accumulate one fresh recovery generation per tick on top of an
#      already-stuck run — under a persistent failure the run count stays flat at one, resumed once
#      per tick, instead of growing without bound.
#
# The crash-gap fallback is NOT the primary future deletion mechanism. The
# primary bridge remains unchanged: Agents::DestroyJob records provenance atomically inside the
# unassignment transaction and, post-commit, hands the cleared conversations to
# Registrar.register_unassigned_after_agent_deletion. The one irreducible gap is a process SIGKILL
# AFTER that transaction commits but BEFORE the post-commit dispatch runs: the conversation is then
# open + unassigned with a durable DeletionProvenance tombstone but no marker and no trigger.
#
# The one-time migration reconciliation cannot close that gap for the future: it runs exactly once
# at deploy with a FIXED historical cutoff, so any provenance recorded AFTER it is excluded forever.
# This drainer closes it by periodically scanning ONLY unreconciled DeletionProvenance tombstones
# (NEVER the conversations table, NEVER all Unassigned conversations) and, when any are old enough to
# be a genuine straggler, running the EXACT existing Reconciler -> Registrar -> Marker ->
# ProcessInboxJob -> InboxProcessor -> native AgentAssignmentService path inline with a fresh
# generation. It never writes assignee_id directly and never introduces a second assignment engine.
#
# Bounded + idempotent + concurrency-safe:
#   * No eligible unreconciled provenance and no incomplete run -> it does NOTHING: no run row, no
#     reconciliation (the existence check is the only work, so an empty system stays completely quiet).
#   * The fresh generation is bucketed to the minute, so two overlapping ticks in the same minute
#     find-or-create the SAME generation and collapse onto one run row (find_or_create_by! absorbs the
#     create race); the Reconciler's global advisory lock then serializes them and the loser no-ops on
#     the already-completed run. Distinct later ticks either resume the still-incomplete run or, once
#     it has completed, find the rows already stamped reconciled_at and scan (near) nothing.
#   * The SAFETY_AGE cutoff keeps the drainer from racing the live post-commit bridge: a tombstone
#     is a candidate only once it is older than the window the bridge would normally complete in, so
#     the drainer only ever adopts real crash-gap stragglers. Everything the bridge already handled
#     is re-checked and stamped reconciled as skipped/ambiguous (idempotent, harmless).
#   * Expected failures (global-lock contention, a transient reconciliation error) are logged and
#     SWALLOWED, never re-raised: the Reconciler leaves the run RUNNING with its committed batches
#     intact, and re-raising would let the job backend (ActiveJob-on-Sidekiq default retry) start a
#     second, unbounded retry tree on top of the cron cadence. The next hourly tick is the bounded
#     retry — it resumes the same still-incomplete generation.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      class RecoveryDrainerJob < ApplicationJob
        # Same queue as the other scheduled/cron jobs (see config/schedule.yml).
        queue_as :scheduled_jobs

        # A provenance tombstone becomes a drainer candidate only once it is older than this, giving
        # the primary post-commit deletion bridge ample time to complete normally first. Short enough
        # that a genuine crash-gap straggler is recovered promptly on the next low-frequency tick.
        SAFETY_AGE = 15.minutes

        def perform
          run = next_run_intent
          return if run.nil?

          reconcile_inline(run)
        end

        private

        # Select AT MOST ONE persisted run intent to process this tick — the amplification guard.
        # An incomplete run (the migration's durable one-time intent, or a run left 'running' by a
        # crash / expected failure on a prior tick) always takes precedence and is processed with its
        # OWN persisted generation/cutoff, so recovery work never fans out while a prior intent is
        # unfinished. Only when NONE is incomplete does it open a fresh recovery generation. Returns
        # nil when there is nothing to do, so an empty/quiet system stays completely quiet.
        def next_run_intent
          ReconciliationRun.incomplete.order(:id).first || open_recovery_run
        end

        # Durably find-or-create exactly ONE fresh recovery run intent iff a genuine crash-gap
        # straggler exists, else nil. The generation is bucketed to the minute so two overlapping
        # ticks in the same minute resolve to the SAME unique generation and collapse onto one row
        # (find_or_create_by! absorbs the create race). The run is persisted HERE, BEFORE any
        # reconciliation, so there is never a window where a generation is being processed without a
        # claimed run row. SAFETY_AGE keeps it from racing the live post-commit bridge.
        def open_recovery_run
          cutoff = Time.current - SAFETY_AGE
          return nil unless DeletionProvenance.unreconciled.exists?(event_at: ...cutoff)

          generation = "recovery-#{Time.current.utc.strftime('%Y%m%d%H%M')}"
          ReconciliationRun.find_or_create_by!(generation: generation) do |row|
            row.status = ReconciliationRun::RUNNING
            row.cutoff_at = cutoff
          end
        end

        # Process the ONE selected run INLINE under the Reconciler's existing GLOBAL advisory lock —
        # NOT via ReconciliationJob.perform_later/perform_now (either would re-enqueue onto the :low
        # queue and, through retry_on, spin an independent retry tree). This drainer is itself a single
        # hourly scheduled cron occurrence, so processing inline keeps recovery to exactly one queued
        # unit per tick.
        #
        # Expected failures are logged and SWALLOWED, never re-raised: the Reconciler already leaves
        # the run RUNNING with its committed batches intact, and re-raising would let ActiveJob's
        # Sidekiq default retry start a second, unbounded retry tree. The bounded retry is the next
        # hourly tick, which resumes this same generation via the incomplete-run branch above.
        def reconcile_inline(run)
          Rails.logger.info("[Wijaya] deferred recovery coordinator reconciling generation=#{run.generation} inline")
          Reconciler.run(generation: run.generation, cutoff: run.cutoff_at)
        rescue Reconciler::LockContention => e
          Rails.logger.info("[Wijaya] deferred recovery coordinator deferred (lock busy): #{e.message}")
        rescue StandardError => e
          Rails.logger.warn("[Wijaya] deferred recovery coordinator reconciliation failed (will retry next tick): #{e.message}")
        end
      end
    end
  end
end
