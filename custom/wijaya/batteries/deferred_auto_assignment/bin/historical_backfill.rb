#!/usr/bin/env ruby
# frozen_string_literal: true

# Canonical operator interface for the deferred auto-assignment HISTORICAL BACKFILL. This is a
# tiny adapter: it loads through the Rails runner (so the Rails environment and the battery
# autoloads are in place) and hands off to the battery-owned BackfillOperator, which parses the
# environment, fails closed, and delegates to the battery services. There is no other operator
# entry point — no rake task, no ad-hoc console snippet.
#
# Dry-run / discovery (safe default, provably read-only — no writes, no enqueues; MODE absent
# or MODE=discover). Full account scan bounded by LIMIT (default 100, max 500):
#   ACCOUNT_ID=<id> [LIMIT=<n>] [INBOX_ID=<id>] \
#     bundle exec rails runner custom/wijaya/batteries/deferred_auto_assignment/bin/historical_backfill.rb
#
# Preview an exact proposed allowlist (reports marker presence + live deferrable?):
#   ACCOUNT_ID=<id> CONVERSATION_IDS=101,102,103 \
#     bundle exec rails runner custom/wijaya/batteries/deferred_auto_assignment/bin/historical_backfill.rb
#
# Apply (requires MODE=apply AND APPLY=1 AND an explicit non-empty CONVERSATION_IDS allowlist;
# fails closed otherwise — nothing from discovery flows in automatically):
#   MODE=apply APPLY=1 ACCOUNT_ID=<id> CONVERSATION_IDS=101,102,103 \
#     bundle exec rails runner custom/wijaya/batteries/deferred_auto_assignment/bin/historical_backfill.rb

begin
  Wijaya::Batteries::DeferredAutoAssignment::BackfillOperator.call
rescue ArgumentError => e
  # Fail closed with a sanitized, non-zero exit (abort -> stderr + exit 1) rather than a raw
  # stack trace, so an invalid/unsafe invocation never looks like it succeeded.
  abort "[deferred_auto_assignment historical backfill] refused: #{e.message}"
end
