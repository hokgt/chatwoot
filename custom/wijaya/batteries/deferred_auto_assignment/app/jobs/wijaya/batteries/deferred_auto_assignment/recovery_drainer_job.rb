# frozen_string_literal: true

# Low-frequency RECOVERY DRAINER + run-intent COORDINATOR for the deferred auto-assignment battery.
#
# Two responsibilities per tick, and each tick is BOUNDED (this is the amplification guard):
#   1. resume_one_incomplete_run — the durable-outbox coordinator. (Re-)enqueue AT MOST ONE
#      incomplete ReconciliationRun per tick. This is how the ONE-TIME historical reconciliation runs
#      safely: its migration persists a 'running' run intent (no fragile Redis perform_later) and this
#      resumes it under new code with the full schema, so Redis downtime or an old worker consuming
#      the job against an incomplete schema can no longer lose it. It also recovers any run left
#      'running' by an exhausted ActiveJob retry.
#   2. drain_crash_gap_provenance — the self-gating crash-gap fallback described below. It runs ONLY
#      when NO incomplete run exists, so a persistent registrar/DB/lock failure can never accumulate
#      one fresh recovery generation per tick on top of an already-stuck run.
#
# Bounded per tick (amplification guard): if ANY incomplete run exists, the tick resumes exactly one
# of them and creates NO new generation; only once every intent has truthfully completed may a tick
# open one new provenance recovery generation. So under a persistent failure the run/job count stays
# flat (one resume per tick) instead of growing without bound.
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
# be a genuine straggler, enqueuing the EXACT existing ReconciliationJob -> Reconciler -> Registrar
# -> Marker -> ProcessInboxJob -> InboxProcessor -> native AgentAssignmentService path with a fresh
# generation. It never writes assignee_id directly and never introduces a second assignment engine.
#
# Bounded + idempotent + concurrency-safe:
#   * No eligible unreconciled provenance -> it does NOTHING: no run row, no ReconciliationJob (the
#     existence check is the only work, so an empty system stays completely quiet).
#   * The generation is bucketed to the minute, so two duplicate/overlapping cron invocations in the
#     same minute enqueue the SAME generation; the ledger's unique generation + the Reconciler's
#     global advisory lock then collapse them to a single run (the loser retries and no-ops on the
#     already-completed run). Distinct later ticks get a fresh generation but find the rows already
#     stamped reconciled_at, so they scan (near) nothing.
#   * The SAFETY_AGE cutoff keeps the drainer from racing the live post-commit bridge: a tombstone
#     is a candidate only once it is older than the window the bridge would normally complete in, so
#     the drainer only ever adopts real crash-gap stragglers. Everything the bridge already handled
#     is re-checked and stamped reconciled as skipped/ambiguous (idempotent, harmless).
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
          # Bounded: if an incomplete run was resumed this tick, do NOT also open a new generation —
          # draining is deferred until every intent has completed. This is the amplification guard.
          return if resume_one_incomplete_run

          drain_crash_gap_provenance
        end

        private

        # Durable-outbox coordinator, BOUNDED to one run per tick: (re-)enqueue the single oldest
        # incomplete run intent and report whether one existed. This is what makes the one-time
        # reconciliation robust WITHOUT a fragile perform_later inside the migration — the migration
        # persists a 'running' run row (started_at NULL, full-history cutoff) and this resumes it here,
        # under new code + full schema, surviving Redis downtime and old-worker timing. It also picks
        # up any run left 'running' by an exhausted ActiveJob retry. The resume reuses the run's OWN
        # persisted cutoff_at; the ledger's unique generation + the Reconciler's global lock make a
        # duplicate/overlapping enqueue idempotent (a completed run is excluded; an in-flight one
        # collapses on the lock). Returning true blocks new-generation creation this tick, so a
        # persistently failing run can never let a fresh recovery generation pile up alongside it.
        def resume_one_incomplete_run
          run = ReconciliationRun.incomplete.order(:id).first
          return false if run.nil?

          Rails.logger.info("[Wijaya] deferred recovery drainer resuming run generation=#{run.generation}")
          ReconciliationJob.perform_later(generation: run.generation, cutoff: run.cutoff_at)
          true
        end

        # Self-gating crash-gap drain (reached ONLY when no incomplete run exists): with no eligible
        # unreconciled provenance, do nothing — no run row, no job (an empty/quiet system stays
        # completely quiet). SAFETY_AGE keeps it from racing the live post-commit bridge. It opens at
        # most ONE new provenance recovery generation; the next tick then sees that run incomplete and
        # resumes it instead of opening another, so recovery work never fans out.
        def drain_crash_gap_provenance
          cutoff = Time.current - SAFETY_AGE
          return unless DeletionProvenance.unreconciled.exists?(event_at: ...cutoff)

          generation = "recovery-#{Time.current.utc.strftime('%Y%m%d%H%M')}"
          Rails.logger.info("[Wijaya] deferred recovery drainer enqueuing reconciliation generation=#{generation}")
          ReconciliationJob.perform_later(generation: generation, cutoff: cutoff)
        end
      end
    end
  end
end
