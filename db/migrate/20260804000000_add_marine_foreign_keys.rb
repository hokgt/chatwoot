# Adds the previously-missing database foreign keys for the Marine AI battery
# tables. Marine relationships were enforced only at the application layer; this
# migration makes them durable at the database level (pre-promotion audit blocker).
#
# Safety:
#   * DDL-only. The only reads are orphan-preflight COUNT(*) probes; there are no
#     inserts / updates / deletes / data copies / seeds.
#   * Each constraint is added only when absent (idempotent) with an explicit,
#     stable name, so a rerun never creates duplicates and `down` removes exactly
#     the constraints this migration owns.
#   * Before adding a constraint the migration aborts if any orphan child rows
#     exist, reporting only a sanitized relationship label and the orphan count --
#     never row data.
#
# Deletion semantics live in the Marine models/concerns: the affected associations
# use synchronous `dependent: :destroy`, so children are removed in the same
# transaction before their parent. That keeps these restrictive (NO ACTION)
# foreign keys satisfied while preserving ActiveStorage / callback cleanup. The
# polymorphic `documentable` association is intentionally left without a database
# foreign key.
class AddMarineForeignKeys < ActiveRecord::Migration[7.1]
  # [from_table, column, to_table] -- parent primary key is always :id.
  MARINE_FOREIGN_KEYS = [
    [:marine_assistants,          :account_id,          :accounts],
    [:marine_documents,           :assistant_id,        :marine_assistants],
    [:marine_documents,           :account_id,          :accounts],
    [:marine_assistant_responses, :assistant_id,        :marine_assistants],
    [:marine_assistant_responses, :account_id,          :accounts],
    [:marine_inboxes,             :marine_assistant_id, :marine_assistants],
    [:marine_inboxes,             :inbox_id,            :inboxes],
    [:marine_custom_tools,        :account_id,          :accounts],
    [:marine_scenarios,           :assistant_id,        :marine_assistants],
    [:marine_scenarios,           :account_id,          :accounts],
    [:marine_copilot_threads,     :account_id,          :accounts],
    [:marine_copilot_threads,     :assistant_id,        :marine_assistants],
    [:marine_copilot_threads,     :user_id,             :users],
    [:marine_copilot_messages,    :account_id,          :accounts],
    [:marine_copilot_messages,    :copilot_thread_id,   :marine_copilot_threads]
  ].freeze

  def up
    MARINE_FOREIGN_KEYS.each do |from_table, column, to_table|
      name = fk_name(from_table, column)
      next if foreign_key_exists?(from_table, to_table, column: column, name: name)

      guard_no_orphans!(from_table, column, to_table)
      add_foreign_key from_table, to_table, column: column, name: name
    end
  end

  def down
    MARINE_FOREIGN_KEYS.reverse_each do |from_table, column, to_table|
      name = fk_name(from_table, column)
      next unless foreign_key_exists?(from_table, to_table, column: column, name: name)

      remove_foreign_key from_table, to_table, column: column, name: name
    end
  end

  private

  # Deterministic, stable, <=63-char PostgreSQL identifier owned by this migration.
  def fk_name(from_table, column)
    "fk_#{from_table}_#{column}"
  end

  # Abort before creating a constraint if any child row references a missing
  # parent. The message is sanitized: only the static relationship label and the
  # integer orphan count are ever surfaced.
  def guard_no_orphans!(from_table, column, to_table)
    orphan_count = connection.select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM #{connection.quote_table_name(from_table)} AS child
      WHERE child.#{connection.quote_column_name(column)} IS NOT NULL
        AND NOT EXISTS (
          SELECT 1
          FROM #{connection.quote_table_name(to_table)} AS parent
          WHERE parent.id = child.#{connection.quote_column_name(column)}
        )
    SQL

    return if orphan_count.zero?

    raise "Marine FK preflight failed for #{from_table}.#{column} -> #{to_table}: " \
          "#{orphan_count} orphaned row(s). Resolve orphans before adding this foreign key."
  end
end
