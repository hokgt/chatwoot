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
      if sql.include?('COUNT(DISTINCT item_code)')
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

  # The authoritative identity is item_code: the active set is deduplicated on item_code BEFORE the
  # page limit, the total is COUNT(DISTINCT item_code), and a blank/whitespace item_code is excluded
  # so it can never become a phantom "" product.
  describe 'item_code dedup and identity' do
    before do
      repository.active_top_level(limit: 1)
      repository.exact_top_level('AAA')
    end

    let(:sqls) { captured.map { |c| c[:sql] } }
    let(:row_sqls) { captured.map { |c| c[:sql] }.reject { |sql| sql.include?('COUNT(') } }

    it 'deduplicates every row query on item_code via DISTINCT ON (item_code)' do
      expect(row_sqls).to all(include('DISTINCT ON (item_code)'))
    end

    it 'counts DISTINCT item_code, never physical rows' do
      # The count query is only issued when has_more; force it with a probe that overflows the page.
      allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
        captured << { sql: sql, params: params }
        next [{ 'total' => 7 }] if sql.include?('COUNT(DISTINCT item_code)')

        [{ 'code' => 'AAA', 'name' => 'Alpha' }, { 'code' => 'BBB', 'name' => 'Bravo' }]
      end
      repository.active_top_level(limit: 1)
      count_sql = captured.last[:sql]
      expect(count_sql).to include('COUNT(DISTINCT item_code)')
      expect(count_sql).not_to include('COUNT(*)')
    end

    it 'guards against a blank/whitespace item_code identity in every query' do
      expect(sqls).to all(include("COALESCE(BTRIM(item_code), '') <> ''"))
    end

    it 'orders deterministically by item_code then item_name (the duplicate-row tiebreak)' do
      expect(row_sqls).to all(include('ORDER BY item_code ASC, item_name ASC'))
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
        expect(result[:has_more]).to be(false)
        expect(captured.length).to eq(1)
        expect(captured.none? { |c| c[:sql].include?('COUNT(') }).to be(true)
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
        expect(result[:has_more]).to be(true)
        expect(result[:total_count]).to eq(42)
        expect(captured.last[:sql]).to include('COUNT(DISTINCT item_code)')
        expect(captured.last[:sql]).to include("disabled = false AND COALESCE(BTRIM(variant_of), '') = ''")
      end

      it 'reports a nil total_count when the COUNT query fails (honest bounded selection)' do
        allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
          captured << { sql: sql, params: params }
          raise StandardError, 'count boom' if sql.include?('COUNT(DISTINCT item_code)')

          listing_rows
        end

        result = repository.active_top_level(limit: 2)
        expect(result[:complete]).to be(false)
        expect(result[:has_more]).to be(true)
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
        # DISTINCT ON (item_code) collapses duplicate physical rows for one item_code to a single
        # identity; LIMIT 2 still surfaces a genuine ambiguity across DISTINCT item_codes.
        expect(call[:sql]).to include('DISTINCT ON (item_code)')
        expect(call[:sql]).to include('LIMIT 2')
        expect(result).to eq(code: 'AAA', name: 'Alpha')
      end
    end

    context 'with duplicate physical rows that the DB collapses to one item_code identity' do
      # DISTINCT ON (item_code) means the DB returns a single row for one item_code even when several
      # physical rows share it, so the lookup resolves rather than manufacturing a false ambiguity.
      let(:exact_rows) { [{ 'code' => 'AAA', 'name' => 'Alpha' }] }

      it 'resolves the single collapsed identity' do
        expect(repository.exact_top_level('AAA')).to eq(code: 'AAA', name: 'Alpha')
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

    context 'with an AMBIGUOUS match across DISTINCT item_codes' do
      # Two different item_codes share the name Alpha — a genuine ambiguity DISTINCT ON does not hide.
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
