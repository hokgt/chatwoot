# frozen_string_literal: true

# Low-frequency, self-gating RECOVERY DRAINER for the deferred auto-assignment battery.
#
# This is a durable-outbox / crash-gap FALLBACK, NOT the primary future deletion mechanism. The
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
          cutoff = Time.current - SAFETY_AGE
          # Self-gate: with no eligible unreconciled provenance, do nothing — no run row, no job.
          return unless DeletionProvenance.unreconciled.exists?(event_at: ...cutoff)

          generation = "recovery-#{Time.current.utc.strftime('%Y%m%d%H%M')}"
          Rails.logger.info("[Wijaya] deferred recovery drainer enqueuing reconciliation generation=#{generation}")
          ReconciliationJob.perform_later(generation: generation, cutoff: cutoff)
        end
      end
    end
  end
end
