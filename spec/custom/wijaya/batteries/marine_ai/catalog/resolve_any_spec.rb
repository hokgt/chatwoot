# frozen_string_literal: true

require 'rails_helper'

# Phase 2A — the narrow batched read-only lookups that back the CatalogCandidateResolver:
# ProductFamilyRepository#resolve_exact_any and VariantRepository#resolve_child_any. The low-level
# Connection is stubbed so no live DB is touched; the examples assert the typed outcomes, the SINGLE
# parameterized statement (no N-query), and that every candidate is a BIND parameter, never interpolated.
RSpec.describe 'Phase 2A batched exact resolution', type: :model do
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

  describe Marine::Catalog::ProductFamilyRepository do
    subject(:repository) { described_class.new }

    it 'returns :missing for a blank/empty candidate set without touching the database' do
      expect(repository.resolve_exact_any([])).to eq(status: :missing)
      expect(repository.resolve_exact_any([nil, '  '])).to eq(status: :missing)
      expect(Marine::Catalog::Connection).not_to have_received(:select)
    end

    context 'with exactly one active family row' do
      let(:stubbed_rows) { [{ 'code' => 'FAM1', 'name' => 'Hull Series' }] }

      it 'resolves in a SINGLE SELECT, matching code OR case-insensitive name via binds (never interpolated)' do
        result = repository.resolve_exact_any(%w[FAM1 santorini])

        expect(result).to eq(status: :resolved, code: 'FAM1', name: 'Hull Series')
        expect(captured.length).to eq(1)
        call = captured.last
        expect(call[:params]).to eq(%w[FAM1 santorini])
        expect(call[:sql]).to include('has_variants = true')
        expect(call[:sql]).to include('disabled = false')
        expect(call[:sql]).to include('item_code IN ($1, $2)')
        expect(call[:sql]).to include('LOWER(item_name) IN (LOWER($1), LOWER($2))')
        expect(call[:sql]).to include('LIMIT 2')
        expect(call[:sql]).not_to include('FAM1')
      end
    end

    context 'with two distinct active family rows' do
      let(:stubbed_rows) { [{ 'code' => 'FAM1', 'name' => 'A' }, { 'code' => 'FAM2', 'name' => 'B' }] }

      it 'fails closed to :ambiguous' do
        expect(repository.resolve_exact_any(%w[Hull])).to eq(status: :ambiguous)
      end
    end

    it 'returns :missing when no row matches' do
      expect(repository.resolve_exact_any(%w[nope])).to eq(status: :missing)
    end

    it 'fails closed to :unavailable on a catalog outage' do
      allow(Marine::Catalog::Connection).to receive(:select).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)
      expect(repository.resolve_exact_any(%w[FAM1])).to eq(status: :unavailable)
    end

    it 'dedupes and caps the candidate binds at MAX_ANY_CANDIDATES' do
      repository.resolve_exact_any((1..100).map { |i| "C#{i}" } + %w[C1 C1])
      expect(captured.last[:params].length).to eq(described_class::MAX_ANY_CANDIDATES)
      expect(captured.last[:params].uniq.length).to eq(captured.last[:params].length)
    end

    it 'drops an over-120-BYTE (multibyte) candidate instead of slicing it into a queryable prefix' do
      multibyte = 'あ' * 41 # 41 * 3 = 123 bytes > 120, but only 41 characters

      repository.resolve_exact_any(['FAM1', multibyte])

      expect(captured.last[:params]).to eq(%w[FAM1])
      expect(captured.last[:params]).not_to include(multibyte[0, described_class::MAX_ANY_CANDIDATE_BYTES])
    end

    it 'keeps a multibyte candidate whose BYTE length is within the bound' do
      multibyte = 'あ' * 40 # 120 bytes exactly

      repository.resolve_exact_any([multibyte])

      expect(captured.last[:params]).to eq([multibyte])
    end
  end

  describe Marine::Catalog::VariantRepository do
    subject(:repository) { described_class.new }

    it 'returns :missing for a blank family or candidate set without touching the database' do
      expect(repository.resolve_child_any('', %w[CH1])).to eq(status: :missing)
      expect(repository.resolve_child_any('FAM1', [])).to eq(status: :missing)
      expect(Marine::Catalog::Connection).not_to have_received(:select)
    end

    context 'with exactly one active child row' do
      let(:stubbed_rows) { [{ 'code' => 'FAM1-CH1' }] }

      it 'resolves exact child code only (family + candidates as binds), in a single SELECT' do
        result = repository.resolve_child_any('FAM1', %w[FAM1-CH1 FAM1-CH2])

        expect(result).to eq(status: :resolved, code: 'FAM1-CH1')
        expect(captured.length).to eq(1)
        call = captured.last
        expect(call[:params]).to eq(%w[FAM1 FAM1-CH1 FAM1-CH2])
        expect(call[:sql]).to include('variant_of = $1')
        expect(call[:sql]).to include('disabled = false')
        expect(call[:sql]).to include('LOWER(item_code) IN (LOWER($2), LOWER($3))')
        expect(call[:sql]).to include('LIMIT 2')
        expect(call[:sql]).not_to include('DISTINCT')
        expect(call[:sql]).not_to include('display')
        expect(call[:sql]).not_to include('attribute')
      end
    end

    # Case-insensitive batched matching against a real-shaped row set. The Connection is faked to
    # emulate Postgres: it honors the predicate the repository actually emits (case-sensitive
    # `item_code IN (...)` vs case-insensitive `LOWER(item_code) IN (LOWER(...))`), filters an in-memory
    # active row set by family (exact) + that predicate, orders by item_code ASC and caps at 2. Result
    # rows are NEVER deduped by case, so a same-family LF-3/lf-3 collision stays :ambiguous.
    context 'with case-insensitive matching over a faked catalog boundary' do
      def fake_catalog(rows)
        allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
          captured << { sql: sql, params: params }
          fake_select(rows, params, sql.include?('LOWER(item_code)'))
        end
      end

      def fake_select(rows, params, case_insensitive)
        family = params.first
        wanted = params.drop(1)
        wanted = wanted.map(&:downcase) if case_insensitive
        rows.select { |r| fake_hit?(r, family, wanted, case_insensitive) }
            .sort_by { |r| r[:item_code] }
            .first(2)
            .map { |r| { 'code' => r[:item_code] } }
      end

      def fake_hit?(row, family, wanted, case_insensitive)
        return false if row[:disabled] || row[:variant_of] != family

        wanted.include?(case_insensitive ? row[:item_code].downcase : row[:item_code])
      end

      it 'resolves the authoritative DB code LF-3 for a lower-case lf-3 candidate' do
        fake_catalog([{ item_code: 'LF-3', variant_of: 'LF', disabled: false }])

        expect(repository.resolve_child_any('LF', %w[lf-3])).to eq(status: :resolved, code: 'LF-3')
        expect(captured.last[:sql]).to include('LOWER(item_code) IN (LOWER($2))')
      end

      it 'fails closed to :ambiguous on a same-family casefold DB collision (LF-3 + lf-3), never collapsing the rows' do
        fake_catalog([{ item_code: 'LF-3', variant_of: 'LF', disabled: false },
                      { item_code: 'lf-3', variant_of: 'LF', disabled: false }])

        expect(repository.resolve_child_any('LF', %w[lf-3])).to eq(status: :ambiguous)
      end

      it 'returns :missing when no active child matches the candidate' do
        fake_catalog([{ item_code: 'LF-3', variant_of: 'LF', disabled: false }])

        expect(repository.resolve_child_any('LF', %w[lf-9])).to eq(status: :missing)
      end
    end

    context 'with two distinct active child rows' do
      let(:stubbed_rows) { [{ 'code' => 'FAM1-CH1' }, { 'code' => 'FAM1-CH2' }] }

      it 'fails closed to :ambiguous' do
        expect(repository.resolve_child_any('FAM1', %w[x y])).to eq(status: :ambiguous)
      end
    end

    it 'fails closed to :unavailable on a catalog outage' do
      allow(Marine::Catalog::Connection).to receive(:select).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)
      expect(repository.resolve_child_any('FAM1', %w[CH1])).to eq(status: :unavailable)
    end

    it 'drops an over-120-BYTE (multibyte) child candidate instead of slicing it into a prefix' do
      multibyte = 'あ' * 41 # 123 bytes > 120

      repository.resolve_child_any('FAM1', ['FAM1-CH1', multibyte])

      expect(captured.last[:params]).to eq(%w[FAM1 FAM1-CH1])
    end
  end
end
