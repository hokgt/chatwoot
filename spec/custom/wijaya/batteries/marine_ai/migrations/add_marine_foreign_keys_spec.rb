# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260804000000_add_marine_foreign_keys')

RSpec.describe AddMarineForeignKeys, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new.tap { |m| m.verbose = false } }

  describe 'installed foreign keys' do
    it 'defines exactly the 15 expected Marine foreign keys with stable names' do
      described_class::MARINE_FOREIGN_KEYS.each do |from_table, column, to_table|
        fk = connection.foreign_keys(from_table.to_s).find { |k| k.column.to_s == column.to_s }

        expect(fk).to be_present, "expected a foreign key on #{from_table}.#{column}"
        expect(fk.to_table).to eq(to_table.to_s)
        expect(fk.name).to eq("fk_#{from_table}_#{column}")
      end
    end

    it 'covers all 15 relationships and none is polymorphic documentable' do
      expect(described_class::MARINE_FOREIGN_KEYS.size).to eq(15)
      columns = described_class::MARINE_FOREIGN_KEYS.map { |_from, column, _to| column }
      expect(columns).not_to include(:documentable_id, :documentable_type)
    end
  end

  describe 'database-level FK enforcement' do
    it 'rejects a marine_custom_tool referencing a missing account' do
      expect do
        connection.execute(<<~SQL.squish)
          INSERT INTO marine_custom_tools (slug, title, endpoint_url, http_method, enabled, account_id, created_at, updated_at)
          VALUES ('fk-probe', 'FK probe', 'https://example.com', 'GET', true, 999999999, now(), now())
        SQL
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it 'rejects a marine_copilot_message referencing a missing thread' do
      account = create(:account)
      expect do
        connection.execute(<<~SQL.squish)
          INSERT INTO marine_copilot_messages (message, message_type, account_id, copilot_thread_id, created_at, updated_at)
          VALUES ('{}'::jsonb, 0, #{account.id}, 999999999, now(), now())
        SQL
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe 'no-orphan preflight guard' do
    it 'passes silently when there are no orphaned rows' do
      expect { migration.send(:guard_no_orphans!, :marine_custom_tools, :account_id, :accounts) }.not_to raise_error
    end

    it 'aborts with a sanitized relationship label and orphan count when an orphan exists' do
      # Drop the FK inside this transactional example so an orphan row can be
      # inserted; the surrounding rollback restores the constraint.
      connection.remove_foreign_key(:marine_custom_tools, :accounts, column: :account_id,
                                                                     name: 'fk_marine_custom_tools_account_id')
      connection.execute(<<~SQL.squish)
        INSERT INTO marine_custom_tools (slug, title, endpoint_url, http_method, enabled, account_id, created_at, updated_at)
        VALUES ('orphan', 'Orphan', 'https://example.com', 'GET', true, 999999999, now(), now())
      SQL

      expect { migration.send(:guard_no_orphans!, :marine_custom_tools, :account_id, :accounts) }
        .to raise_error(/marine_custom_tools\.account_id -> accounts: 1 orphaned row/)
    end
  end
end
