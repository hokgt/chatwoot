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
    it 'keeps only active sellable non-child rows, without using has_variants as the top-level discriminator' do
      expect(described_class::TOP_LEVEL_PREDICATE)
        .to eq("disabled = false AND is_sales_item = true AND COALESCE(BTRIM(variant_of), '') = ''")
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
        expect(call[:sql]).to include(described_class::TOP_LEVEL_PREDICATE)
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
        expect(captured.last[:sql]).to include(described_class::TOP_LEVEL_PREDICATE)
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

  describe '#active_item_groups' do
    it 'returns a bounded authoritative category page without enumerating item rows' do
      allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
        captured << { sql: sql, params: params }
        [{ 'item_group' => 'Fabric' }, { 'item_group' => 'Yarn' }]
      end

      result = repository.active_item_groups(limit: 20)

      expect(captured.first[:sql]).to include('GROUP BY LOWER(BTRIM(item_group))')
      expect(captured.first[:sql]).to include('is_sales_item = true')
      expect(captured.first[:sql]).to include("COALESCE(BTRIM(item_code), '') <> ''")
      expect(captured.first[:sql]).not_to include('item_code AS code')
      expect(captured.first[:params]).to eq([21])
      expect(result).to eq(item_groups: %w[Fabric Yarn], returned_count: 2, total_count: 2,
                           complete: true, has_more: false)
    end

    it 'normalizes case/whitespace identity before page, count, and exact lookup' do
      calls = []
      allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
        calls << { sql: sql, params: params }
        if sql.include?('COUNT(DISTINCT LOWER(BTRIM(item_group)))')
          [{ 'total' => 2 }]
        elsif sql.include?('LOWER(BTRIM(item_group)) = $1')
          [{ 'item_group' => 'Fabric' }]
        else
          [{ 'item_group' => 'Fabric' }, { 'item_group' => 'Yarn' }]
        end
      end

      page = repository.active_item_groups(limit: 1)
      exact = repository.exact_item_group(' fabric ')

      expect(page).to include(item_groups: ['Fabric'], returned_count: 1, total_count: 2, complete: false)
      expect(exact).to eq('Fabric')
      expect(calls[0][:sql]).to include('MIN(BTRIM(item_group))', 'GROUP BY LOWER(BTRIM(item_group))')
      expect(calls[1][:sql]).to include('COUNT(DISTINCT LOWER(BTRIM(item_group)))')
      expect(calls[2][:sql]).to include('GROUP BY LOWER(BTRIM(item_group))')
    end

    it 'uses deterministic normalized Item Group display and ordering before LIMIT' do
      repository.active_item_groups(limit: 1)
      sql = captured.first[:sql]
      expect(sql).to include('MIN(BTRIM(item_group)) AS item_group')
      expect(sql).to include('ORDER BY normalized_group ASC')
      expect(sql.index('GROUP BY')).to be < sql.index('LIMIT')
    end

    it 'fails closed on malformed category rows' do
      allow(Marine::Catalog::Connection).to receive(:select).and_return([{ 'item_group' => nil }])
      expect { repository.active_item_groups }.to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
    end
  end

  describe 'category-specific top-level listing' do
    it 'resolves an exact category and applies it to page and count queries with the sellable non-child predicate' do
      calls = []
      allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
        calls << { sql: sql, params: params }
        if sql.include?('GROUP BY LOWER(BTRIM(item_group))')
          [{ 'item_group' => 'Fabric' }]
        elsif sql.include?('COUNT(DISTINCT item_code)')
          [{ 'total' => 3 }]
        else
          [{ 'code' => 'AAA', 'name' => 'Alpha' }, { 'code' => 'BBB', 'name' => 'Bravo' }]
        end
      end

      category = repository.exact_item_group(' fabric ')
      result = repository.active_top_level(item_group: category, limit: 1)

      expect(category).to eq('Fabric')
      expect(calls[0][:params]).to eq(['fabric'])
      expect(calls[1][:params]).to eq([2, 'Fabric'])
      expect(calls[2][:params]).to eq(['Fabric'])
      expect(calls.drop(1).map { |call| call[:sql] }).to all(include('LOWER(BTRIM(item_group)) = LOWER(BTRIM('))
      expect(calls.drop(1).map { |call| call[:sql] }).to all(include(described_class::TOP_LEVEL_PREDICATE))
      expect(result[:products]).to eq([{ code: 'AAA', name: 'Alpha' }])
      expect(result).to include(returned_count: 1, total_count: 3, complete: false, has_more: true)
    end

    it 'fails closed rather than broadening an explicitly blank category scope' do
      expect(Marine::Catalog::Connection).not_to receive(:select)
      expect { repository.active_top_level(item_group: '   ') }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
    end

    it 'returns nil for an absent or ambiguous exact category and fails closed on outage' do
      allow(Marine::Catalog::Connection).to receive(:select).and_return([])
      expect(repository.exact_item_group('Ghost')).to be_nil
      allow(Marine::Catalog::Connection).to receive(:select).and_return([{ 'item_group' => 'A' }, { 'item_group' => 'B' }])
      expect(repository.exact_item_group('group')).to be_nil
      allow(Marine::Catalog::Connection).to receive(:select).and_raise(StandardError)
      expect { repository.exact_item_group('Fabric') }.to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
    end
  end

  describe 'bounded cross-namespace resolution' do
    it 'binds every candidate and retains normalized Item Group ambiguity' do
      allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
        captured << { sql: sql, params: params }
        sql.include?('normalized_group') ? [{ 'item_group' => 'Fabric' }] : []
      end

      result = repository.resolve_item_group_any(%w[Fabric Yarn])
      expect(result).to eq(status: :resolved, item_group: 'Fabric')
      expect(captured.first[:params]).to eq(%w[Fabric Yarn])
      expect(captured.first[:sql]).to include('LOWER(BTRIM(item_group)) IN (LOWER($1), LOWER($2))')
    end

    it 'returns ambiguous when two normalized product identities match' do
      allow(Marine::Catalog::Connection).to receive(:select).and_return(
        [{ 'code' => 'A', 'name' => 'Alpha' }, { 'code' => 'B', 'name' => 'Beta' }]
      )
      expect(repository.resolve_top_level_any(%w[Alpha Beta])).to eq(status: :ambiguous)
    end

    it 'normalizes exact product code and name identities before matching' do
      allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
        captured << { sql: sql, params: params }
        [{ 'code' => 'KAIN-1', 'name' => 'Kain Premium' }]
      end

      expect(repository.resolve_top_level_any([' kain-1 '])).to eq(
        status: :resolved, code: 'KAIN-1', name: 'Kain Premium'
      )
      expect(captured.first[:params]).to eq(['kain-1'])
      expect(captured.first[:sql]).to include('LOWER(BTRIM(item_code)) IN (LOWER($1))')
      expect(captured.first[:sql]).to include('LOWER(BTRIM(item_name)) IN (LOWER($1))')
    end

    it 'infers one Item Group when all exact token-boundary product matches converge' do
      allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
        captured << { sql: sql, params: params }
        [{ 'item_code' => 'KAIN-1', 'normalized_group' => 'fabric', 'item_group' => 'Fabric', 'display_count' => '1' },
         { 'item_code' => 'KAIN-2', 'normalized_group' => 'fabric', 'item_group' => 'Fabric', 'display_count' => '1' }]
      end

      result = repository.infer_item_group_from_top_level_any(['kain'])
      expect(result).to eq(status: :resolved, item_group: 'Fabric')
      expect(captured.first[:params]).to eq(['kain'])
      expect(captured.first[:sql]).to include(described_class::AUTHORITATIVE_PREDICATE)
      expect(captured.first[:sql]).to match(/\ASELECT\b/i)
      expect(captured.first[:sql]).to include('FROM (VALUES ($1)) AS candidates(value)')
      expect(Marine::Catalog::Connection.single_select?(captured.first[:sql])).to be(true)
      expect(captured.first[:sql]).to include("regexp_split_to_array(LOWER(CONCAT_WS(' ', item_code, item_name))")
      expect(captured.first[:sql]).to include("LIMIT #{described_class::MAX_INFERENCE_MATCHES + 1}")
    end

    it 'fails closed when matching products span normalized Item Groups' do
      allow(Marine::Catalog::Connection).to receive(:select).and_return(
        [{ 'item_code' => 'KAIN-1', 'normalized_group' => 'fabric', 'item_group' => 'Fabric', 'display_count' => '1' },
         { 'item_code' => 'KAIN-2', 'normalized_group' => 'apparel', 'item_group' => 'Apparel', 'display_count' => '1' }]
      )
      expect(repository.infer_item_group_from_top_level_any(['kain'])).to eq(status: :ambiguous)
    end

    it 'fails closed on display conflicts, overflow, and outage' do
      conflict = [{ 'item_code' => 'KAIN-1', 'normalized_group' => 'fabric', 'item_group' => 'Fabric', 'display_count' => '2' }]
      allow(Marine::Catalog::Connection).to receive(:select).and_return(conflict)
      expect(repository.infer_item_group_from_top_level_any(['kain'])).to eq(status: :ambiguous)

      overflow = (1..(described_class::MAX_INFERENCE_MATCHES + 1)).map do |index|
        { 'item_code' => "KAIN-#{index}", 'normalized_group' => 'fabric', 'item_group' => 'Fabric', 'display_count' => '1' }
      end
      allow(Marine::Catalog::Connection).to receive(:select).and_return(overflow)
      expect(repository.infer_item_group_from_top_level_any(['kain'])).to eq(status: :ambiguous)

      allow(Marine::Catalog::Connection).to receive(:select).and_raise(StandardError)
      expect(repository.infer_item_group_from_top_level_any(['kain'])).to eq(status: :unavailable)
    end
  end

  describe '#exact_top_level' do
    context 'with a single unique match' do
      let(:exact_rows) { [{ 'code' => 'AAA', 'name' => 'Alpha' }] }

      it 'binds the exact code and the lowered name and carries the canonical predicate' do
        result = repository.exact_top_level(' Alpha ')
        call = captured.first
        expect(call[:params]).to eq(%w[Alpha alpha])
        expect(call[:sql]).to include(described_class::TOP_LEVEL_PREDICATE)
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
