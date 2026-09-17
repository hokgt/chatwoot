# frozen_string_literal: true

# Apply side of the historical backfill (operator-invoked, one-time). Takes an EXPLICIT
# account id and an EXPLICIT conversation-id allowlist, validates them, and enqueues a single
# bounded background job that runs the exact live pipeline through the historical Registrar
# entry point. Nothing from HistoricalDiscovery flows in automatically — the caller must pass
# the ids they approved.
#
# Fail closed: a missing/empty allowlist raises before anything is enqueued. Cross-account and
# non-existent ids are rejected DISTINCTLY (partitioned and reported) and never enqueued; the
# job additionally re-scopes to account_id, so a stray cross-account id could not be acted on
# even if it reached the job. Bounded: at most MAX_BATCH ids per apply, dispatched as ONE
# BackfillJob (no per-id job fan-out, no queue explosion); the existing per-inbox coalescing
# then dedupes processing passes.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module HistoricalBackfill
        module_function

        MAX_BATCH = 500

        # Returns a partition summary: { in_account:, cross_account:, missing:, enqueued: }.
        # Raises ArgumentError on a missing account, an empty allowlist, or an oversized batch.
        def run(account_id:, conversation_ids:)
          account_id = normalize_account_id(account_id)
          ids = normalize_ids(conversation_ids)
          raise ArgumentError, 'conversation_ids allowlist is required and must be non-empty' if ids.empty?
          raise ArgumentError, "conversation_ids exceeds MAX_BATCH (#{MAX_BATCH})" if ids.size > MAX_BATCH

          partition = partition_ids(account_id, ids)
          enqueue_backfill(account_id, partition[:in_account])
          partition.merge(enqueued: partition[:in_account])
        end

        def enqueue_backfill(account_id, in_account_ids)
          return if in_account_ids.empty?

          BackfillJob.perform_later(account_id: account_id, conversation_ids: in_account_ids)
        end

        # Fails closed before any enqueue: the id must be a positive integer AND name an account
        # that actually exists (a well-formed but non-existent account id is rejected here, not
        # silently carried into partitioning/enqueue).
        def normalize_account_id(account_id)
          value = account_id.to_i
          raise ArgumentError, 'account_id is required' unless value.positive?
          raise ArgumentError, "account_id #{value} does not exist" unless Account.exists?(id: value)

          value
        end

        # Accepts an Array or a comma/whitespace-separated String of STRICTLY POSITIVE integer
        # ids and returns them deduped. Fails closed on any malformed or non-positive token
        # (e.g. "abc", "1.5", "0", "-3") rather than silently dropping it and applying a
        # partially-changed allowlist. An empty result still fails closed in run.
        def normalize_ids(conversation_ids)
          raw = conversation_ids.is_a?(String) ? conversation_ids.split(/[,\s]+/) : Array(conversation_ids)
          tokens = raw.map { |token| token.to_s.strip }.reject(&:empty?)
          tokens.map { |token| positive_integer!(token) }.uniq
        end

        def positive_integer!(token)
          value = Integer(token, 10, exception: false)
          raise ArgumentError, "invalid conversation id: #{token.inspect}" unless value&.positive?

          value
        end

        # Distinct rejection: an id absent from the DB -> missing; present but owned by another
        # account -> cross_account; present and owned by this account -> in_account (candidate).
        def partition_ids(account_id, ids)
          owner_by_id = Conversation.where(id: ids).pluck(:id, :account_id).to_h
          result = { in_account: [], cross_account: [], missing: [] }
          ids.each do |id|
            owner = owner_by_id[id]
            if owner.nil?
              result[:missing] << id
            elsif owner == account_id
              result[:in_account] << id
            else
              result[:cross_account] << id
            end
          end
          result
        end
      end
    end
  end
end
