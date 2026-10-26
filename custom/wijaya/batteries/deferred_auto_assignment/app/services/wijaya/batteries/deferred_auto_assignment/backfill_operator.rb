# frozen_string_literal: true

# Operator adapter for the deferred auto-assignment HISTORICAL BACKFILL. It is the single
# canonical operator interface, invoked through the battery-owned runner script:
#
#   bundle exec rails runner custom/wijaya/batteries/deferred_auto_assignment/bin/historical_backfill.rb
#
# It only parses the environment, delegates to the battery services (HistoricalDiscovery for
# read-only discovery, HistoricalBackfill for the explicit-allowlist apply), and prints a
# human-readable summary. It holds NO business logic and touches NO marker / job / assignment
# state directly — every write goes through HistoricalBackfill.run.
#
# Fail closed, dry-run by default:
#   * MODE absent or MODE=discover -> read-only discovery/dry-run (never writes, never enqueues).
#   * MODE=apply requires BOTH APPLY=1 AND an explicit non-empty CONVERSATION_IDS allowlist;
#     anything else raises before any work is enqueued.
#   * ACCOUNT_ID must be an explicit positive integer.
#   * An unknown MODE or invalid params raise ArgumentError (the runner turns that into a
#     non-zero exit).
#
# Discovery evidence is review material only: it explicitly says no changes were made and that
# evidence is never approval. Customer incoming/outgoing message bodies are never emitted — the
# discovery service already limits evidence to bounded assignment-related ACTIVITY lines.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      class BackfillOperator
        DEFAULT_MODE = 'discover'
        VALID_MODES = %w[discover apply].freeze

        # env defaults to the process ENV; out defaults to $stdout. Both are injectable so the
        # MODE/APPLY gating is unit-testable without a subprocess or global-state capture.
        def self.call(env: ENV, out: $stdout)
          new(env, out).call
        end

        def initialize(env, out)
          @env = env
          @out = out
        end

        def call
          resolved_mode = mode
          account_id = require_account_id!
          case resolved_mode
          when 'discover' then run_discover(account_id)
          when 'apply' then run_apply(account_id)
          end
        end

        private

        # Fails closed on an unknown MODE; absent/blank MODE defaults to safe discovery.
        def mode
          value = @env['MODE'].to_s.strip
          value = DEFAULT_MODE if value.empty?
          raise ArgumentError, "unknown MODE #{value.inspect} (expected discover or apply)" unless VALID_MODES.include?(value)

          value
        end

        def require_account_id!
          value = positive_integer('ACCOUNT_ID', @env['ACCOUNT_ID'])
          raise ArgumentError, 'ACCOUNT_ID is required and must be a positive integer' if value.nil?

          value
        end

        def run_discover(account_id)
          evidence = HistoricalDiscovery.discover(
            account_id: account_id,
            limit: limit,
            inbox_id: inbox_id,
            conversation_ids: conversation_ids
          )
          print_discovery(account_id, evidence)
          evidence
        end

        # Apply gate: BOTH APPLY=1 AND an explicit non-empty CONVERSATION_IDS allowlist are
        # mandatory. HistoricalBackfill.run performs the authoritative id/account validation and
        # is the ONLY path that enqueues work.
        def run_apply(account_id)
          raise ArgumentError, 'refusing to apply without APPLY=1 (run MODE=discover for a read-only dry run)' unless @env['APPLY'] == '1'

          ids = raw_conversation_ids
          raise ArgumentError, 'apply requires an explicit non-empty CONVERSATION_IDS allowlist' if ids.nil?

          summary = HistoricalBackfill.run(account_id: account_id, conversation_ids: ids)
          print_apply(account_id, summary)
          summary
        end

        # Absent/blank -> default. Present must be a strictly positive integer string (fails
        # closed on malformed/non-positive); a valid value is still clamped to MAX_LIMIT by the
        # discovery service.
        def limit
          positive_integer('LIMIT', @env['LIMIT']) || HistoricalDiscovery::DEFAULT_LIMIT
        end

        # Absent/blank -> nil (no inbox narrowing). Present must be a strictly positive integer
        # string (fails closed on malformed/non-positive), normalized to an Integer.
        def inbox_id
          positive_integer('INBOX_ID', @env['INBOX_ID'])
        end

        # Strict parse for operator-supplied numeric env values. Absent/blank -> nil. Otherwise
        # the value MUST be a bare positive integer string (e.g. '3abc', '1.5', '0', '-3' all
        # fail closed) so a malformed value can never be silently coerced.
        def positive_integer(name, raw)
          value = raw.to_s.strip
          return nil if value.empty?
          raise ArgumentError, "#{name} must be a positive integer" unless value.match?(/\A\d+\z/) && value.to_i.positive?

          value.to_i
        end

        # Absent/blank -> nil (default scan for discovery, refusal for apply). Present -> split
        # into tokens; the services validate them.
        def conversation_ids
          raw_conversation_ids&.split(/[,\s]+/)
        end

        def raw_conversation_ids
          @env['CONVERSATION_IDS'].to_s.strip.presence
        end

        def print_discovery(account_id, evidence)
          @out.puts "DRY RUN — #{evidence.size} candidate(s) for account #{account_id}. No changes made."
          @out.puts 'Evidence is for review only; it is never approval and nothing flows into apply automatically.'
          evidence.each do |row|
            activity = row[:latest_assignment_activity]
            @out.puts "- conversation ##{row[:conversation_id]} (display ##{row[:display_id]}) inbox=#{row[:inbox_id]} " \
                      "team=#{row[:team_id].inspect} status=#{row[:status]} assignee=#{row[:assignee_id].inspect} " \
                      "bot=#{row[:assignee_agent_bot_id].inspect} marker=#{row[:marker_present]} " \
                      "deferrable=#{row[:deferrable]} apparent_target=#{row[:apparent_target]} " \
                      "erp_lead=#{row[:linked_erp_lead]} created=#{row[:created_at]} updated=#{row[:updated_at]}"
            @out.puts "    activity: #{activity[:content]} (at #{activity[:created_at]})" if activity
          end
        end

        def print_apply(account_id, summary)
          @out.puts "APPLY — account #{account_id}"
          @out.puts "  enqueued (in-account):    #{summary[:enqueued].join(', ')}"
          @out.puts "  rejected (cross-account): #{summary[:cross_account].join(', ')}" if summary[:cross_account].any?
          @out.puts "  rejected (missing):       #{summary[:missing].join(', ')}" if summary[:missing].any?
          if summary[:enqueued].any?
            @out.puts '  A single bounded BackfillJob was enqueued; assignment runs through the existing pipeline.'
          else
            @out.puts '  No BackfillJob was enqueued (no in-account ids to process).'
          end
        end
      end
    end
  end
end
