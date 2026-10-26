# frozen_string_literal: true

# Shared contract for the PostgreSQL BEFORE DELETE trigger that keeps the reconciliation run ledger's
# terminal-disposition counters truthful when a reconciliation-owned marker is removed by a DB-level
# DELETE that fires NO Rails callback — the on_delete: :cascade paths (a parent
# account/inbox/conversation deleted via conversation.delete_all / destroy_async, or any direct FK
# cascade). Without it, a cascade would delete a still-waiting marker without transitioning its run
# counter, so the ledger would keep a stale no_eligible_agent and miss the dropped it should record.
#
# Why a trigger (not solely a Ruby callback): a DB cascade bypasses ActiveRecord entirely, so an
# after_destroy can never observe it. The trigger fires inside the SAME transaction as the DELETE,
# so its ledger UPDATE is atomic with the marker removal and rolls back with it — truthful for the
# cascade path, the delete_all path, AND the ordinary Rails destroy path (has_one dependent:
# :destroy), which now relies on this trigger instead of a Ruby after_destroy.
#
# WHERE THE TRIGGER LIVES: it is declared once, with the repository's HairTrigger create_trigger DSL,
# in migration 20260912000008. HairTrigger creates the trigger FUNCTION before the CREATE TRIGGER and
# dumps a matching create_trigger block into db/schema.rb, so BOTH migrate-forward installs and fresh
# db:schema:load installs reconstruct it in the correct order. There is deliberately NO boot-time
# CREATE OR REPLACE FUNCTION anywhere (app/Sidekiq startup does no DDL); a fresh schema install works
# from db/schema.rb itself. This module therefore carries only the shared suppression constant, so
# the migration/trigger and the Ruby resolution path can never disagree about the GUC name.
#
# Explicit-resolution suppression protocol: Marker.resolve_and_record deletes a marker AND records
# the precise disposition (ASSIGNED / DROPPED) in Ruby, under a row lock, reading the marker's real
# previous bucket. So that path sets this transaction-local GUC around its delete; the trigger sees
# it ('on') and does NOTHING, leaving the richer Ruby accounting authoritative. Every other delete
# (no GUC set) falls through to the trigger's default terminal DROPPED transition. This is how the
# two sources never double-count.
#
# Nested (not compact) to match the sibling battery files.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module MarkerDropTrigger
        # Names the migration/trigger own; kept here purely for reference and cross-file grepping.
        # With the HairTrigger DSL the generated function shares the trigger's name.
        TRIGGER = 'wijaya_deferred_marker_drop_trg'

        # Transaction-local GUC (a customized two-part option, valid to SET without prior definition)
        # that an explicit Ruby resolution sets so the trigger skips its default accounting — see the
        # suppression protocol above. current_setting(..., true) returns NULL (missing_ok) when unset.
        # This literal MUST stay in step with the current_setting('...') check baked into the trigger
        # body in migration 20260912000008.
        SKIP_SETTING = 'wijaya.deferred_skip_marker_drop'
      end
    end
  end
end
