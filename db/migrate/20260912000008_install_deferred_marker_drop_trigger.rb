# WIJAYA_CUSTOM_START deferred_auto_assignment
# Installs the PostgreSQL BEFORE DELETE trigger that keeps the reconciliation run ledger's
# terminal-disposition counters truthful when a reconciliation-owned marker is removed by a DB-level
# DELETE that fires no Rails callback — the on_delete: :cascade paths established by
# 20260912000005 (conversation.delete_all / destroy_async / any parent FK cascade).
#
# Without it, a cascade deletes a still-waiting marker without transitioning its run counter, so the
# ledger keeps a stale no_eligible_agent and misses the dropped it should record. The trigger fires
# inside the same transaction as the DELETE, so its ledger UPDATE is atomic with the marker removal
# and rolls back with it. Marker.resolve_and_record suppresses the trigger for its own delete (it
# records the precise ASSIGNED/DROPPED outcome in Ruby), so the two sources never double-count.
#
# The trigger definition lives in the shared MarkerDropTrigger service and is (re-)asserted
# idempotently on boot by the battery loader too — schema.rb (:ruby format) cannot represent a
# trigger, so this migration covers migrate-forward installs and the loader covers db:schema:load /
# fresh-schema environments; both call the same install! so the definition never drifts.
#
# Forward-only + idempotent (install! CREATE OR REPLACE FUNCTION + create-trigger-if-absent under an
# advisory lock). Reversible: down removes the trigger + function.
class InstallDeferredMarkerDropTrigger < ActiveRecord::Migration[7.1]
  def up
    Wijaya::Batteries::DeferredAutoAssignment::MarkerDropTrigger.install!(connection)
  end

  def down
    Wijaya::Batteries::DeferredAutoAssignment::MarkerDropTrigger.remove!(connection)
  end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
