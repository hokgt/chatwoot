# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::VariantResolver do
  subject(:resolver) { described_class.new(variant_repository: variant_repository) }

  let(:variant_repository) { instance_double(Marine::Catalog::VariantRepository) }

  before do
    # Default: nothing resolves unless a specific example says so.
    allow(variant_repository).to receive(:resolve_child).and_return(nil)
    allow(variant_repository).to receive(:resolve_by_attribute).and_return(nil)
    allow(variant_repository).to receive(:attribute_names).and_return([])
  end

  describe 'blank family' do
    it 'is missing without touching the repository' do
      expect(resolver.resolve(family_code: '  ')).to eq(status: :unresolved, reason: :missing)
      expect(variant_repository).not_to have_received(:resolve_child)
    end
  end

  describe 'explicit child code' do
    it 'resolves ONLY the row-derived code within the family' do
      allow(variant_repository).to receive(:resolve_child).with('FAM-1', 'CHILD-1').and_return(code: 'CHILD-1')

      expect(resolver.resolve(family_code: 'FAM-1', explicit_child_code: 'CHILD-1'))
        .to eq(status: :resolved, code: 'CHILD-1')
    end

    it 'is missing when the code does not match a child row' do
      expect(resolver.resolve(family_code: 'FAM-1', explicit_child_code: 'NOPE'))
        .to eq(status: :unresolved, reason: :missing)
    end
  end

  describe 'attribute/value candidates' do
    before do
      allow(variant_repository).to receive(:attribute_names).with('FAM-1').and_return(%w[Size Colour])
    end

    it 'accepts exactly one unique row-derived child across bounded name/value combinations' do
      allow(variant_repository).to receive(:resolve_by_attribute).with('FAM-1', 'Size', '10').and_return(code: 'CHILD-10')

      expect(resolver.resolve(family_code: 'FAM-1', attribute_candidates: ['10']))
        .to eq(status: :resolved, code: 'CHILD-10')
    end

    it 'is ambiguous — never first-picked — when two distinct children match' do
      allow(variant_repository).to receive(:resolve_by_attribute).with('FAM-1', 'Size', '10').and_return(code: 'CHILD-10')
      allow(variant_repository).to receive(:resolve_by_attribute).with('FAM-1', 'Colour', '10').and_return(code: 'CHILD-99')

      expect(resolver.resolve(family_code: 'FAM-1', attribute_candidates: ['10']))
        .to eq(status: :unresolved, reason: :ambiguous)
    end

    it 'collapses duplicate hits on the same child to a single unique code' do
      allow(variant_repository).to receive(:resolve_by_attribute).and_return(code: 'CHILD-10')

      expect(resolver.resolve(family_code: 'FAM-1', attribute_candidates: %w[10 red]))
        .to eq(status: :resolved, code: 'CHILD-10')
    end
  end

  describe 'combined explicit code + attribute pointing at different children' do
    it 'is ambiguous when the paths disagree' do
      allow(variant_repository).to receive(:resolve_child).with('FAM-1', 'CHILD-1').and_return(code: 'CHILD-1')
      allow(variant_repository).to receive(:attribute_names).with('FAM-1').and_return(%w[Size])
      allow(variant_repository).to receive(:resolve_by_attribute).with('FAM-1', 'Size', '10').and_return(code: 'CHILD-2')

      expect(resolver.resolve(family_code: 'FAM-1', explicit_child_code: 'CHILD-1', attribute_candidates: ['10']))
        .to eq(status: :unresolved, reason: :ambiguous)
    end
  end

  describe 'fail-closed on catalog error' do
    it 'propagates CatalogUnavailableError (never fabricates a code)' do
      allow(variant_repository).to receive(:resolve_child).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)

      expect { resolver.resolve(family_code: 'FAM-1', explicit_child_code: 'CHILD-1') }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
    end
  end

  # Legacy path end-to-end through the REAL VariantRepository, with only the low-level Connection
  # boundary faked (it honors the exact predicate the repository emits). A lower-case explicit child
  # code resolves the authoritative DB code — proving the resolver carries the row code, never the input.
  describe 'case-insensitive explicit child code through the real repository' do
    subject(:resolver) { described_class.new(variant_repository: Marine::Catalog::VariantRepository.new) }

    before do
      allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
      allow(Marine::Catalog::Config).to receive(:qualified_table).and_return('marine_ai.item')
      allow(Marine::Catalog::Config).to receive(:schema).and_return('marine_ai')
      allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
        family = params[0]
        candidates = params[1..]
        case_insensitive = sql.include?('LOWER(item_code)')
        [{ item_code: 'LF-3', variant_of: 'LF', disabled: false }]
          .select { |r| r[:variant_of] == family && candidates.any? { |c| case_insensitive ? r[:item_code].casecmp?(c) : r[:item_code] == c } }
          .map { |r| { 'code' => r[:item_code] } }
      end
    end

    it 'resolves the row-derived code LF-3 for a lower-case lf-3 input' do
      expect(resolver.resolve(family_code: 'LF', explicit_child_code: 'lf-3'))
        .to eq(status: :resolved, code: 'LF-3')
    end
  end
end
