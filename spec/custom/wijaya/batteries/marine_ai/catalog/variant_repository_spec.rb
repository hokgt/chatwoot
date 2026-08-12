# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::VariantRepository, type: :model do
  subject(:repository) { described_class.new }

  # The low-level Connection is always stubbed so no live external DB is touched. We
  # capture the exact SQL text and, crucially, the bind parameters — proving client input
  # is always passed as parameters and child codes come from rows, never concatenation.
  let(:captured) { [] }
  let(:stubbed_rows) { [] }

  before do
    allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
    allow(Marine::Catalog::Config).to receive(:qualified_table).and_return('marine_ai.item')
    allow(Marine::Catalog::Config).to receive(:schema).and_return('marine_ai')
    allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
      captured << { sql: sql, params: params }
      stubbed_rows
    end
  end

  describe '#resolve_child' do
    context 'with a blank family or child code' do
      it 'returns nil without touching the database' do
        expect(repository.resolve_child('', 'CHILD-1')).to be_nil
        expect(repository.resolve_child('FAM-1', '  ')).to be_nil
        expect(repository.resolve_child(nil, nil)).to be_nil
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end

    context 'when exactly one active child matches' do
      let(:stubbed_rows) { [{ 'code' => 'CHILD-1' }] }

      it 'returns the row-derived child code and binds family + child as params' do
        expect(repository.resolve_child('FAM-1', 'CHILD-1')).to eq(code: 'CHILD-1')

        call = captured.last
        expect(call[:params]).to eq(%w[FAM-1 CHILD-1])
        expect(call[:sql]).to include('marine_ai.item')
        expect(call[:sql]).to include('variant_of = $1 AND item_code = $2 AND disabled = false')
        expect(call[:sql]).to include('LIMIT 2')
        expect(call[:sql]).not_to include('CHILD-1')
        expect(call[:sql]).not_to include('FAM-1')
      end
    end

    context 'when no child matches' do
      let(:stubbed_rows) { [] }

      it 'returns nil (not found)' do
        expect(repository.resolve_child('FAM-1', 'NOPE')).to be_nil
      end
    end

    context 'when the match is ambiguous' do
      let(:stubbed_rows) { [{ 'code' => 'CHILD-1' }, { 'code' => 'CHILD-2' }] }

      it 'returns nil and never picks the first ambiguous row' do
        expect(repository.resolve_child('FAM-1', 'CHILD-1')).to be_nil
      end
    end

    context 'when the catalog is not configured' do
      it 'fails closed with CatalogUnavailableError' do
        allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
        expect { repository.resolve_child('FAM-1', 'CHILD-1') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end
  end

  describe '#attribute_names' do
    let(:stubbed_rows) { [{ 'name' => 'ATTR-A' }, { 'name' => 'ATTR-B' }] }

    it 'returns distinct row-derived names, bounded and deterministically ordered' do
      expect(repository.attribute_names('FAM-1')).to eq(%w[ATTR-A ATTR-B])

      call = captured.last
      expect(call[:params]).to eq(['FAM-1', described_class::MAX_ATTRIBUTE_NAMES])
      expect(call[:sql]).to include('SELECT DISTINCT attribute AS name')
      expect(call[:sql]).to include('marine_ai.item_variant_attribute')
      expect(call[:sql]).to include('variant_of = $1 AND disabled = false')
      expect(call[:sql]).to include('ORDER BY attribute ASC')
      expect(call[:sql]).to include('LIMIT $2')
      expect(call[:sql]).not_to include("LIMIT #{described_class::MAX_ATTRIBUTE_NAMES}")
    end

    it 'returns an empty array for a blank family without touching the database' do
      expect(repository.attribute_names('  ')).to eq([])
      expect(Marine::Catalog::Connection).not_to have_received(:select)
    end

    context 'when the catalog is not configured' do
      it 'fails closed with CatalogUnavailableError' do
        allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
        expect { repository.attribute_names('FAM-1') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
      end
    end
  end

  describe '#resolve_by_attribute' do
    context 'with a blank family, attribute, or value' do
      it 'returns nil without touching the database' do
        expect(repository.resolve_by_attribute('', 'ATTR-A', 'VAL-1')).to be_nil
        expect(repository.resolve_by_attribute('FAM-1', ' ', 'VAL-1')).to be_nil
        expect(repository.resolve_by_attribute('FAM-1', 'ATTR-A', '')).to be_nil
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end

    context 'when exactly one active child matches the attribute/value' do
      let(:stubbed_rows) { [{ 'code' => 'CHILD-1' }] }

      it 'joins item and item_variant_attribute, binds all three params, and returns the row code' do
        expect(repository.resolve_by_attribute('FAM-1', 'ATTR-A', 'VAL-1')).to eq(code: 'CHILD-1')

        call = captured.last
        expect(call[:params]).to eq(%w[FAM-1 ATTR-A VAL-1])
        expect(call[:sql]).to include('JOIN marine_ai.item_variant_attribute a ON a.parent = i.name')
        expect(call[:sql]).to include('i.variant_of = $1')
        expect(call[:sql]).to include('a.variant_of = $1')
        expect(call[:sql]).to include('a.attribute = $2')
        expect(call[:sql]).to include('a.attribute_value = $3')
        expect(call[:sql]).to include('i.disabled = false')
        expect(call[:sql]).to include('a.disabled = false')
        expect(call[:sql]).to include('LIMIT 2')
        expect(call[:sql]).not_to include('VAL-1')
      end
    end

    context 'when no child matches' do
      let(:stubbed_rows) { [] }

      it 'returns nil (not found)' do
        expect(repository.resolve_by_attribute('FAM-1', 'ATTR-A', 'VAL-1')).to be_nil
      end
    end

    context 'when the match is ambiguous' do
      let(:stubbed_rows) { [{ 'code' => 'CHILD-1' }, { 'code' => 'CHILD-2' }] }

      it 'returns nil and never picks the first ambiguous row' do
        expect(repository.resolve_by_attribute('FAM-1', 'ATTR-A', 'VAL-1')).to be_nil
      end
    end

    context 'when the catalog is not configured' do
      it 'fails closed with CatalogUnavailableError' do
        allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
        expect { repository.resolve_by_attribute('FAM-1', 'ATTR-A', 'VAL-1') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
      end
    end
  end
end
