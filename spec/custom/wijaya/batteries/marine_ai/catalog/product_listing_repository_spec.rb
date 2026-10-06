# frozen_string_literal: true

require 'rails_helper'

# Phase 3 — bounded, deterministic catalog LISTING of active TOP-LEVEL products (templates +
# standalone; variants and disabled excluded). Every example stubs the low-level Connection so no
# live external DB is touched; we assert the exact canonical top-level predicate (shared VERBATIM by
# page / count / exact lookup), the page+1 bind that makes completeness known, the exact completeness
# metadata, and the exact single-product lookup. The predicate's row-level semantics (a NULL vs
# blank-string vs child vs disabled variant_of) are PROVEN by the SQL predicate asserted here and
# validated empirically by the read-only runtime aggregate proof.
RSpec.describe Marine::Catalog::ProductListingRepository, type: :model do
  subject(:repository) { described_class.new }

  let(:captured) { [] }
  let(:listing_rows) { [] }
  let(:exact_rows) { [] }
  let(:count_rows) { [{ 'total' => 0 }] }

  before do
    allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
    allow(Marine::Catalog::Config).to receive(:qualified_table).and_return('marine_ai.item')
    allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
      captured << { sql: sql, params: params }
      if sql.include?('COUNT(*)')
        count_rows
      elsif sql.include?('item_code = $1')
        exact_rows
      else
        listing_rows
      end
    end
  end

  # The one canonical top-level predicate every query must carry VERBATIM: active, and NOT a child
  # (a NULL or blank/whitespace variant_of is kept; only a row naming a parent family is dropped).
  describe 'the canonical top-level predicate' do
    it 'keeps disabled=false AND the empty-variant_of test, never a plain variant_of IS NULL, and no has_variants' do
      expect(described_class::TOP_LEVEL_PREDICATE).to eq("disabled = false AND COALESCE(BTRIM(variant_of), '') = ''")
    end

    it 'shares that exact predicate across page, count, and exact lookup' do
      repository.active_top_level(limit: 1)
      repository.exact_top_level('AAA')
      sqls = captured.map { |c| c[:sql] }
      expect(sqls).to all(include(described_class::TOP_LEVEL_PREDICATE))
      # A child variant (variant_of names a parent), a blank-string standalone, and a NULL standalone
      # are all discriminated by this single predicate; a disabled row is excluded by disabled=false.
      expect(sqls).to all(satisfy { |sql| sql.exclude?('variant_of IS NULL') })
      expect(sqls).to all(satisfy { |sql| sql.exclude?('has_variants') })
    end
  end

  describe '#active_top_level' do
    context 'when the page is the whole set (no extra row)' do
      let(:listing_rows) { [{ 'code' => 'AAA', 'name' => 'Alpha' }, { 'code' => 'BBB', 'name' => 'Bravo' }] }

      it 'lists top-level active products, orders by item_code, and binds page+1' do
        result = repository.active_top_level(limit: 20)

        call = captured.first
        expect(call[:params]).to eq([21])
        expect(call[:sql]).to include("disabled = false AND COALESCE(BTRIM(variant_of), '') = ''")
        expect(call[:sql]).to include('ORDER BY item_code ASC')
        expect(call[:sql]).to include('LIMIT $1')
        expect(result[:products]).to eq([{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }])
      end

      it 'reports complete with returned_count == total_count and issues NO count query' do
        result = repository.active_top_level(limit: 20)

        expect(result[:returned_count]).to eq(2)
        expect(result[:total_count]).to eq(2)
        expect(result[:complete]).to be(true)
        expect(captured.length).to eq(1)
        expect(captured.none? { |c| c[:sql].include?('COUNT(*)') }).to be(true)
      end
    end

    context 'when there is more than one page (an extra row comes back)' do
      let(:listing_rows) do
        [{ 'code' => 'AAA', 'name' => 'Alpha' }, { 'code' => 'BBB', 'name' => 'Bravo' }, { 'code' => 'CCC', 'name' => 'Charlie' }]
      end
      let(:count_rows) { [{ 'total' => 42 }] }

      it 'truncates to the page, reports has_more via complete=false, and fills total from COUNT' do
        result = repository.active_top_level(limit: 2)

        expect(captured.first[:params]).to eq([3])
        expect(result[:products]).to eq([{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }])
        expect(result[:returned_count]).to eq(2)
        expect(result[:complete]).to be(false)
        expect(result[:total_count]).to eq(42)
        expect(captured.last[:sql]).to include('COUNT(*)')
        expect(captured.last[:sql]).to include("disabled = false AND COALESCE(BTRIM(variant_of), '') = ''")
      end

      it 'reports a nil total_count when the COUNT query fails (honest bounded selection)' do
        allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
          captured << { sql: sql, params: params }
          raise StandardError, 'count boom' if sql.include?('COUNT(*)')

          listing_rows
        end

        result = repository.active_top_level(limit: 2)
        expect(result[:complete]).to be(false)
        expect(result[:total_count]).to be_nil
      end
    end

    describe 'limit clamping' do
      let(:listing_rows) { [] }

      it 'clamps above MAX_PAGE down to MAX_PAGE (+1 for the probe)' do
        repository.active_top_level(limit: 9_999)
        expect(captured.first[:params]).to eq([described_class::MAX_PAGE + 1])
      end

      it 'falls back to DEFAULT_PAGE for a non-positive limit' do
        repository.active_top_level(limit: 0)
        expect(captured.first[:params]).to eq([described_class::DEFAULT_PAGE + 1])
        repository.active_top_level(limit: -5)
        expect(captured.last[:params]).to eq([described_class::DEFAULT_PAGE + 1])
      end
    end

    context 'when the catalog is not configured' do
      it 'fails closed with CatalogUnavailableError without touching the database' do
        allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
        expect { repository.active_top_level }.to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end
  end

  describe '#exact_top_level' do
    context 'with a single unique match' do
      let(:exact_rows) { [{ 'code' => 'AAA', 'name' => 'Alpha' }] }

      it 'binds the exact code and the lowered name and carries the canonical predicate' do
        result = repository.exact_top_level(' Alpha ')
        call = captured.first
        expect(call[:params]).to eq(%w[Alpha alpha])
        expect(call[:sql]).to include("disabled = false AND COALESCE(BTRIM(variant_of), '') = ''")
        expect(call[:sql]).to include('item_code = $1 OR LOWER(item_name) = $2')
        expect(call[:sql]).to include('LIMIT 2')
        expect(result).to eq(code: 'AAA', name: 'Alpha')
      end
    end

    it 'returns nil for a blank mention without touching the database' do
      expect(repository.exact_top_level('   ')).to be_nil
      expect(repository.exact_top_level(nil)).to be_nil
      expect(Marine::Catalog::Connection).not_to have_received(:select)
    end

    context 'with no match' do
      let(:exact_rows) { [] }

      it 'returns nil' do
        expect(repository.exact_top_level('ZZZ')).to be_nil
      end
    end

    context 'with an AMBIGUOUS (non-unique) match' do
      let(:exact_rows) { [{ 'code' => 'AAA', 'name' => 'Alpha' }, { 'code' => 'AAB', 'name' => 'Alpha' }] }

      it 'returns nil rather than guessing the first row' do
        expect(repository.exact_top_level('Alpha')).to be_nil
      end
    end

    it 'fails closed with CatalogUnavailableError when not configured' do
      allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
      expect { repository.exact_top_level('AAA') }.to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
    end
  end
end
