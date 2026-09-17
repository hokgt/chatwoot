# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260912000004_add_deferred_provenance_deletion_key')

# The 4-column occurrence index legitimately allows DISTINCT deletion occurrences of the same
# conversation+agent to coexist (each keyed by its own deletion_key). Rolling back would require
# re-adding the old 3-column unique index, which such rows now violate — a down that would fail
# nondeterministically after valid production data. The migration is therefore irreversible by
# design; the forward index is unchanged.
RSpec.describe AddDeferredProvenanceDeletionKey, type: :model do
  let(:migration) { described_class.new.tap { |m| m.verbose = false } }
  let(:connection) { ActiveRecord::Base.connection }

  it 'raises IrreversibleMigration on down instead of a nondeterministic rollback' do
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  it 'keeps the forward 4-column occurrence unique index in place' do
    index = connection.indexes(described_class::TABLE.to_s).find { |i| i.name == described_class::NEW_INDEX }

    expect(index).to be_present
    expect(index.unique).to be(true)
    expect(index.columns).to eq(%w[conversation_id prior_assignee_id event deletion_key])
  end
end
