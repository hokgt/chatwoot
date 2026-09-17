# WIJAYA_CUSTOM_START deferred_auto_assignment
# Compatibility no-op (was: the one-time reconciliation enqueue).
#
# The enqueue originally lived here, BEFORE 20260912000002 added the correlation columns and the
# full counter set that the corrected ReconciliationJob/Reconciler now require. During a deploy an
# already-running Sidekiq worker could consume that job in the window after this migration ran but
# before 20260912000002 completed, failing against an incomplete schema (missing
# reconciliation_generation / identified / … columns). The enqueue has therefore been moved to
# 20260912000003_enqueue_deferred_assignment_reconciliation_after_schema, which runs AFTER every
# schema prerequisite. This migration is now an intentional no-op, kept in place because it may
# already be recorded in schema_migrations on some environments; the one-time reconciliation
# semantics are preserved by the unique generation on the new enqueue migration.
class EnqueueDeferredAssignmentReconciliation < ActiveRecord::Migration[7.1]
  def up; end

  def down; end
end
# WIJAYA_CUSTOM_END deferred_auto_assignment
