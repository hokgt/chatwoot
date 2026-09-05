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

        # At most one job per inbox in-flight; the token lets a job release only its own claim.
        def self.enqueue_for_inbox(inbox_id)
          key = format(IN_FLIGHT_KEY, inbox_id: inbox_id)
          token = SecureRandom.uuid
          return false unless ::Redis::Alfred.set(key, token, nx: true, ex: IN_FLIGHT_TTL)

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
        end

        private

        def release_in_flight(inbox_id, token)
          return if token.nil?

          ::Redis::Alfred.delete_if_equals(format(IN_FLIGHT_KEY, inbox_id: inbox_id), token)
        end
      end
    end
  end
end
