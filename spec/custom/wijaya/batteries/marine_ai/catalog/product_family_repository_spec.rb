# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::ProductFamilyRepository, type: :model do
  subject(:repository) { described_class.new }

  # Every example stubs the low-level Connection so no live external DB is ever
  # touched. We assert on the exact SQL text and, more importantly, the bind
  # parameters — proving client input is passed as parameters, never interpolated.
  let(:captured) { [] }
  let(:stubbed_rows) { [] }

  before do
    allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
    allow(Marine::Catalog::Config).to receive(:qualified_table).and_return('marine_ai.item')
    allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
      captured << { sql: sql, params: params }
      stubbed_rows
    end
  end

  describe '#exists?' do
    context 'with a blank code' do
      it 'returns false without touching the database' do
        expect(repository.exists?('')).to be(false)
        expect(repository.exists?('   ')).to be(false)
        expect(repository.exists?(nil)).to be(false)
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end

    context 'with a present code' do
      let(:stubbed_rows) { [{ '?column?' => 1 }] }

      it 'matches an EXACT family template (item_code + has_variants) via bind $1, never interpolated' do
        expect(repository.exists?('HULL-9000')).to be(true)

        call = captured.last
        expect(call[:params]).to eq(['HULL-9000'])
        expect(call[:sql]).to include('WHERE item_code = $1 AND has_variants = true')
        expect(call[:sql]).to include('marine_ai.item ')
        expect(call[:sql]).not_to include('HULL-9000')
        expect(call[:sql]).not_to include('variant_of')
      end

      it 'strips surrounding whitespace from the code' do
        repository.exists?('  HULL-9000  ')
        expect(captured.last[:params]).to eq(['HULL-9000'])
      end
    end

    context 'when no row is returned' do
      let(:stubbed_rows) { [] }

      it 'returns false' do
        expect(repository.exists?('NOPE')).to be(false)
      end
    end

    context 'when the catalog is not configured' do
      it 'fails closed with CatalogUnavailableError' do
        allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
        expect { repository.exists?('HULL-9000') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end
  end

  describe '#search' do
    let(:stubbed_rows) do
      [
        { 'code' => 'AAA', 'name' => 'Alpha' },
        { 'code' => 'BBB', 'name' => 'Bravo' }
      ]
    end

    it 'selects family templates (has_variants), binds params, and orders by item_code' do
      result = repository.search(query: 'hull', limit: 10)

      call = captured.last
      expect(call[:params]).to eq(['hull', '%hull%', 10])
      expect(call[:sql]).to include('WHERE has_variants = true')
      expect(call[:sql]).to include('item_code AS code')
      expect(call[:sql]).to include('item_name AS name')
      expect(call[:sql]).to include('ORDER BY item_code ASC')
      expect(call[:sql]).to include('$1')
      expect(call[:sql]).to include('$2')
      expect(call[:sql]).to include('$3')
      expect(call[:sql]).not_to include('hull%')
      expect(call[:sql]).not_to include('variant_of')
      expect(result).to eq([{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }])
    end

    it 'escapes LIKE wildcards in the client query so they match literally' do
      repository.search(query: '50%_x')
      expect(captured.last[:params][1]).to eq('%50\\%\\_x%')
    end

    it 'defaults a blank query to an empty normalized string' do
      repository.search
      expect(captured.last[:params][0]).to eq('')
    end

    it 'truncates an oversized query to MAX_QUERY_LENGTH before building binds' do
      long = 'a' * (described_class::MAX_QUERY_LENGTH + 25)
      repository.search(query: long)
      expect(captured.last[:params][0]).to eq('a' * described_class::MAX_QUERY_LENGTH)
      expect(captured.last[:params][1]).to eq("%#{'a' * described_class::MAX_QUERY_LENGTH}%")
    end

    describe 'limit clamping' do
      it 'clamps above MAX_LIMIT down to MAX_LIMIT' do
        repository.search(query: 'x', limit: 9_999)
        expect(captured.last[:params][2]).to eq(described_class::MAX_LIMIT)
      end

      it 'falls back to DEFAULT_LIMIT for a non-positive limit' do
        repository.search(query: 'x', limit: 0)
        expect(captured.last[:params][2]).to eq(described_class::DEFAULT_LIMIT)
        repository.search(query: 'x', limit: -5)
        expect(captured.last[:params][2]).to eq(described_class::DEFAULT_LIMIT)
      end
    end

    context 'when the catalog is not configured' do
      it 'fails closed with CatalogUnavailableError' do
        allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
        expect { repository.search(query: 'x') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
      end
    end
  end

  describe '#resolve_exact' do
    context 'with a blank identifier' do
      it 'returns nil without touching the database' do
        expect(repository.resolve_exact('')).to be_nil
        expect(repository.resolve_exact('   ')).to be_nil
        expect(repository.resolve_exact(nil)).to be_nil
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end

    context 'when exactly one active family template matches' do
      let(:stubbed_rows) { [{ 'code' => 'FAM-1', 'name' => 'Family One' }] }

      it 'resolves the single row, binds the identifier, and requires an active template' do
        expect(repository.resolve_exact('FAM-1')).to eq(code: 'FAM-1', name: 'Family One')

        call = captured.last
        expect(call[:params]).to eq(['FAM-1'])
        expect(call[:sql]).to include('has_variants = true')
        expect(call[:sql]).to include('disabled = false')
        expect(call[:sql]).to include('item_code = $1 OR LOWER(item_name) = LOWER($1)')
        expect(call[:sql]).to include('LIMIT 2')
        expect(call[:sql]).not_to include('FAM-1')
      end

      it 'strips surrounding whitespace from the identifier' do
        repository.resolve_exact('  FAM-1  ')
        expect(captured.last[:params]).to eq(['FAM-1'])
      end
    end

    context 'when no family matches' do
      let(:stubbed_rows) { [] }

      it 'returns nil (not found)' do
        expect(repository.resolve_exact('NOPE')).to be_nil
      end
    end

    context 'when the match is ambiguous' do
      let(:stubbed_rows) do
        [{ 'code' => 'FAM-1', 'name' => 'Family One' }, { 'code' => 'FAM-2', 'name' => 'Family Two' }]
      end

      it 'returns nil and never picks the first ambiguous row' do
        expect(repository.resolve_exact('AMBIG')).to be_nil
      end
    end

    context 'when the catalog is not configured' do
      it 'fails closed with CatalogUnavailableError' do
        allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
        expect { repository.resolve_exact('FAM-1') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end
  end

  describe '#active_candidates' do
    let(:stubbed_rows) do
      [
        { 'code' => 'FAM-1', 'name' => 'Family One' },
        { 'code' => 'FAM-2', 'name' => 'Family Two' }
      ]
    end

    it 'lists only active family templates, binds params, and orders by item_code' do
      result = repository.active_candidates(query: 'fam', limit: 10)

      call = captured.last
      expect(call[:params]).to eq(['fam', '%fam%', 10])
      expect(call[:sql]).to include('has_variants = true')
      expect(call[:sql]).to include('disabled = false')
      expect(call[:sql]).to include('ORDER BY item_code ASC')
      expect(call[:sql]).to include('$3')
      expect(result).to eq([{ code: 'FAM-1', name: 'Family One' }, { code: 'FAM-2', name: 'Family Two' }])
    end

    it 'clamps the limit to MAX_LIMIT' do
      repository.active_candidates(query: 'x', limit: 9_999)
      expect(captured.last[:params][2]).to eq(described_class::MAX_LIMIT)
    end

    context 'when the catalog is not configured' do
      it 'fails closed with CatalogUnavailableError' do
        allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
        expect { repository.active_candidates(query: 'x') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
      end
    end
  end
end
