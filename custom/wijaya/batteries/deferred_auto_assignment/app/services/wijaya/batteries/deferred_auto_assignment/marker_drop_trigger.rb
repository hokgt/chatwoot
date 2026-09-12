# frozen_string_literal: true

# Installs (idempotently) the PostgreSQL BEFORE DELETE trigger that keeps the reconciliation run
# ledger's terminal-disposition counters truthful when a reconciliation-owned marker is removed by
# a DB-level DELETE that fires NO Rails callback — the on_delete: :cascade paths (a parent
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
# Explicit-resolution suppression protocol: Marker.resolve_and_record deletes a marker AND records
# the precise disposition (ASSIGNED / DROPPED) in Ruby, under a row lock, reading the marker's real
# previous bucket. So that path sets a transaction-local GUC (SKIP_SETTING) around its delete; the
# trigger sees it and does NOTHING, leaving the richer Ruby accounting authoritative. Every other
# delete (no GUC set) falls through to the trigger's default terminal DROPPED transition. This is
# how the two sources never double-count.
#
# Why installed from BOTH a migration AND the battery loader: schema.rb (:ruby format) cannot
# represent a trigger, so a fresh install via db:schema:load would never get it. The forward
# migration (20260912000008) covers migrate-forward installs; the loader's to_prepare re-asserts it
# idempotently on boot so schema:load / fresh-schema environments also carry it. Both call the same
# install! so the definition can never drift.
#
# Nested (not compact) to match the sibling battery files.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module MarkerDropTrigger
        module_function

        TABLE = 'wijaya_deferred_assignments'
        RUNS_TABLE = 'wijaya_deferred_reconciliation_runs'
        FUNCTION = 'wijaya_deferred_marker_record_drop'
        TRIGGER = 'wijaya_deferred_marker_drop_trg'

        # Transaction-local GUC (a customized two-part option, valid to SET without prior definition)
        # that an explicit Ruby resolution sets so the trigger skips its default accounting — see the
        # suppression protocol above. current_setting(..., true) returns NULL (missing_ok) when unset.
        SKIP_SETTING = 'wijaya.deferred_skip_marker_drop'

        # This battery's advisory-lock namespace (shared with the Reconciler's ADVISORY_NAMESPACE),
        # with a distinct key so a concurrent multi-process boot serializes trigger (re)installation
        # without ever colliding with the reconciliation run lock.
        ADVISORY_NAMESPACE = 0x77494a41
        ADVISORY_KEY = 1

        def install!(connection = ActiveRecord::Base.connection)
          return unless connection.data_source_exists?(TABLE) && connection.data_source_exists?(RUNS_TABLE)

          # requires_new so this is safe whether called standalone (loader boot) or inside a running
          # migration transaction; the xact advisory lock serializes concurrent boots and releases at
          # transaction end. CREATE OR REPLACE FUNCTION is always safe; the trigger is created only if
          # absent (steady-state boots do no DDL beyond the idempotent function replace).
          connection.transaction(requires_new: true) do
            connection.execute("SELECT pg_advisory_xact_lock(#{ADVISORY_NAMESPACE}, #{ADVISORY_KEY})")
            connection.execute(function_sql)
            connection.execute(trigger_sql) unless trigger_exists?(connection)
          end
        end

        def remove!(connection = ActiveRecord::Base.connection)
          connection.execute("DROP TRIGGER IF EXISTS #{TRIGGER} ON #{TABLE}")
          connection.execute("DROP FUNCTION IF EXISTS #{FUNCTION}()")
        end

        def trigger_exists?(connection)
          connection.select_value(
            "SELECT 1 FROM pg_trigger WHERE tgname = #{connection.quote(TRIGGER)} AND NOT tgisinternal"
          ).present?
        end

        # Default terminal disposition for a callback-less delete: transition the marker's last
        # bucket -> dropped, exactly once, floored at zero — mirroring ReconciliationRun.record_outcome
        # (increment the new bucket, GREATEST(old - 1, 0) the previous one, no-op when already dropped).
        # A no-op for an ordinary marker (blank generation) and when suppressed by SKIP_SETTING.
        # rubocop:disable Metrics/MethodLength
        def function_sql
          <<~SQL.squish
            CREATE OR REPLACE FUNCTION #{FUNCTION}() RETURNS trigger AS $fn$
            BEGIN
              IF OLD.reconciliation_generation IS NULL OR OLD.reconciliation_generation = '' THEN
                RETURN OLD;
              END IF;
              IF current_setting('#{SKIP_SETTING}', true) = 'on' THEN
                RETURN OLD;
              END IF;
              IF OLD.reconciliation_outcome = 'dropped' THEN
                RETURN OLD;
              END IF;
              UPDATE #{RUNS_TABLE}
                 SET dropped = dropped + 1,
                     no_eligible_agent = CASE WHEN OLD.reconciliation_outcome = 'no_eligible_agent'
                       THEN GREATEST(no_eligible_agent - 1, 0) ELSE no_eligible_agent END,
                     assigned = CASE WHEN OLD.reconciliation_outcome = 'assigned'
                       THEN GREATEST(assigned - 1, 0) ELSE assigned END,
                     updated_at = NOW()
               WHERE generation = OLD.reconciliation_generation;
              RETURN OLD;
            END;
            $fn$ LANGUAGE plpgsql;
          SQL
        end
        # rubocop:enable Metrics/MethodLength

        def trigger_sql
          "CREATE TRIGGER #{TRIGGER} BEFORE DELETE ON #{TABLE} " \
            "FOR EACH ROW EXECUTE FUNCTION #{FUNCTION}()"
        end
      end
    end
  end
end
