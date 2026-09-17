# frozen_string_literal: true

# Bounded background worker for the historical backfill. Runs the historical Registrar entry
# point for an account-scoped allowlist, which marks each still-eligible conversation and
# enqueues the existing coalesced per-inbox ProcessInboxJob — i.e. the exact live pipeline
# (Eligibility -> Marker -> ProcessInboxJob -> InboxProcessor -> native AgentAssignmentService
# -> conversation.update! -> ERP owner callback). No selector, no direct assignee write, and
# no new ERP path live here.
#
# Idempotent under retry: the historical entry point re-runs Eligibility.deferrable? per id and
# find_or_create_by! is keyed on the unique conversation_id, so a retried job never double-marks
# and an already-assigned / resolved / marked id is a safe no-op. The batch is re-validated here
# (defense in depth): a caller that bypassed HistoricalBackfill and enqueued a non-Array, empty,
# oversized, or non-positive-integer payload fails closed rather than being silently truncated.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      class BackfillJob < ApplicationJob
        queue_as :default

        def perform(account_id:, conversation_ids:)
          validate_batch!(conversation_ids)
          Registrar.register_unassigned_historical(account_id, conversation_ids)
        end

        private

        # Defense in depth for a caller that bypassed HistoricalBackfill and enqueued this job
        # directly. It re-validates the payload WITHOUT enqueuing another job: a non-Array,
        # empty, oversized, or non-positive-integer batch fails closed (raises) rather than
        # silently truncating with first(MAX_BATCH) and dropping approved ids. The normal
        # HistoricalBackfill.run path already produces a validated in-account id list, so this is
        # a no-op guard there.
        def validate_batch!(conversation_ids)
          raise ArgumentError, 'conversation_ids must be a non-empty Array' unless conversation_ids.is_a?(Array) && conversation_ids.any?

          if conversation_ids.size > HistoricalBackfill::MAX_BATCH
            raise ArgumentError, "conversation_ids exceeds MAX_BATCH (#{HistoricalBackfill::MAX_BATCH})"
          end
          return if conversation_ids.all? { |id| id.is_a?(Integer) && id.positive? }

          raise ArgumentError, 'conversation_ids must all be positive integers'
        end
      end
    end
  end
end
