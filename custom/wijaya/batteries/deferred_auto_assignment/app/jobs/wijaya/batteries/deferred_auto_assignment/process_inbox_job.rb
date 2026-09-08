# frozen_string_literal: true

# Coalesced per-inbox processing of deferred-assignment markers. Multiple agents coming
# online at once (or availability + presence firing for the same agent) would otherwise
# enqueue redundant scans of the same inbox; the in-flight Redis marker keeps at most one
# job per inbox queued-or-running, mirroring AutoAssignment::AssignmentJob's pattern but
# with a battery-OWNED key so it never reads, writes, or steals the Assignment V2 key.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      class ProcessInboxJob < ApplicationJob
        queue_as :default

        IN_FLIGHT_TTL = 5.minutes
        IN_FLIGHT_KEY = 'WIJAYA_DEFERRED_ASSIGNMENT_IN_FLIGHT::%<inbox_id>d'
        # A trigger that arrives while a job is already in-flight cannot enqueue a second job
        # (the in-flight key coalesces it away), so it records a rerun request instead. The
        # running job consumes that request AFTER releasing its own claim and enqueues exactly
        # one more pass, so state that changed mid-scan is never dropped and there is no busy
        # loop: a rerun happens only because a real trigger fired during the scan. The TTL bounds
        # the request so a crashed worker cannot leave it stuck forever.
        RERUN_TTL = 5.minutes
        RERUN_KEY = 'WIJAYA_DEFERRED_ASSIGNMENT_RERUN::%<inbox_id>d'

        # At most one job per inbox in-flight; the token lets a job release only its own claim.
        def self.enqueue_for_inbox(inbox_id)
          key = format(IN_FLIGHT_KEY, inbox_id: inbox_id)
          token = SecureRandom.uuid
          unless ::Redis::Alfred.set(key, token, nx: true, ex: IN_FLIGHT_TTL)
            # Coalesced: a job is already queued-or-running for this inbox. Ask it to run once
            # more so work created after it started its scan is still picked up.
            ::Redis::Alfred.set(format(RERUN_KEY, inbox_id: inbox_id), '1', ex: RERUN_TTL)
            return false
          end

          return true if perform_later(inbox_id: inbox_id, token: token)

          ::Redis::Alfred.delete_if_equals(key, token)
          false
        rescue StandardError
          ::Redis::Alfred.delete_if_equals(key, token)
          raise
        end

        def perform(inbox_id:, token: nil)
          InboxProcessor.process(inbox_id)
        ensure
          release_in_flight(inbox_id, token)
          consume_rerun(inbox_id)
        end

        private

        def release_in_flight(inbox_id, token)
          return if token.nil?

          ::Redis::Alfred.delete_if_equals(format(IN_FLIGHT_KEY, inbox_id: inbox_id), token)
        end

        # Release-first, then consume: the in-flight claim is dropped BEFORE the rerun request is
        # read, so any trigger that failed to enqueue (and therefore set the request) while we
        # held the claim is observed here, while any trigger arriving after the release takes the
        # normal enqueue path. delete returns the number of keys removed, giving an atomic
        # get-and-clear so the request is consumed exactly once.
        def consume_rerun(inbox_id)
          return unless ::Redis::Alfred.delete(format(RERUN_KEY, inbox_id: inbox_id)).to_i.positive?

          self.class.enqueue_for_inbox(inbox_id)
        end
      end
    end
  end
end
