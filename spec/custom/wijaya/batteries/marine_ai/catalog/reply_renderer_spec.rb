# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::ReplyRenderer do
  subject(:renderer) { described_class.new }

  describe 'parent / variant info' do
    it 'renders parent info from a row-derived family' do
      expect(renderer.parent_info(code: 'FAM-1', name: 'Impeller')).to eq(
        kind: :parent_info, family_code: 'FAM-1', family_name: 'Impeller'
      )
    end

    it 'renders variant info from a validated family + row-derived child code' do
      expect(renderer.variant_info({ code: 'FAM-1', name: 'Impeller' }, 'CHILD-9')).to eq(
        kind: :variant_info, family_code: 'FAM-1', variant_code: 'CHILD-9'
      )
    end

    it 'renders a direct catalog descriptor from a row-derived family' do
      expect(renderer.catalog(code: 'FAM-1', name: 'Impeller')).to eq(
        kind: :catalog, family_code: 'FAM-1', family_name: 'Impeller'
      )
    end
  end

  describe 'price' do
    it 'copies through ONLY the three approved price fields plus the validated variant code' do
      price = { status: :available, price_list_rate: '125.50', currency: 'USD', uom: 'Nos', secret: 'x' }

      expect(renderer.price_available(price, 'CHILD-1')).to eq(
        kind: :price_available, variant_code: 'CHILD-1', price_list_rate: '125.50', currency: 'USD', uom: 'Nos'
      )
    end

    it 'renders factless unavailable / conflict descriptors' do
      expect(renderer.price_unavailable).to eq(kind: :price_unavailable)
      expect(renderer.price_conflict).to eq(kind: :price_conflict)
    end
  end

  describe 'stock' do
    it 'renders binary status carrying only the validated variant code — never a quantity or warehouse fact' do
      expect(renderer.stock_available('BD-RED')).to eq(kind: :stock_available, variant_code: 'BD-RED')
      expect(renderer.stock_empty('BD-RED')).to eq(kind: :stock_empty, variant_code: 'BD-RED')
      expect(renderer.stock_unavailable).to eq(kind: :stock_unavailable)
    end

    it 'control-char-cleans and length-bounds the variant code, dropping a blank/non-scalar one to nil' do
      expect(renderer.stock_available("BD#{0.chr}RED")).to eq(kind: :stock_available, variant_code: 'BD RED')
      expect(renderer.stock_available('X' * 200)).to eq(kind: :stock_available, variant_code: 'X' * described_class::MAX_CODE_NAME_LENGTH)
      expect(renderer.stock_available('   ')).to eq(kind: :stock_available, variant_code: nil)
      expect(renderer.stock_empty(%w[not scalar])).to eq(kind: :stock_empty, variant_code: nil)
    end
  end

  describe 'clarifications' do
    it 'bounds and normalizes safe family candidates' do
      candidates = Array.new(15) { |i| { code: "FAM-#{i}", name: "Name #{i}", extra: 'drop' } }

      result = renderer.clarify_family(candidates)

      expect(result[:kind]).to eq(:clarify_family)
      expect(result[:candidates].length).to eq(described_class::MAX_CANDIDATES)
      expect(result[:candidates].first).to eq(code: 'FAM-0', name: 'Name 0')
    end

    it 'bounds variant clarification to the family attribute names' do
      names = Array.new(20) { |i| "attr#{i}" }

      result = renderer.clarify_variant(names)

      expect(result[:kind]).to eq(:clarify_variant)
      expect(result[:attribute_names].length).to eq(described_class::MAX_ATTRIBUTE_NAMES)
    end

    it 'control-char-cleans and length-bounds candidate codes/names, dropping malformed rows' do
      candidates = [
        { code: "FAM#{0.chr}1", name: "Imp\teller" },
        { code: '   ', name: 'blank code dropped' },
        { code: %w[not a scalar], name: 'nonscalar code dropped' },
        { code: 'X' * 200, name: 'Y' * 200 }
      ]

      result = renderer.clarify_family(candidates)

      expect(result[:candidates]).to eq(
        [
          { code: 'FAM 1', name: 'Imp eller' },
          { code: 'X' * described_class::MAX_CODE_NAME_LENGTH, name: 'Y' * described_class::MAX_CODE_NAME_LENGTH }
        ]
      )
    end

    it 'control-char-cleans and length-bounds attribute names, dropping blank ones' do
      names = ["Si#{7.chr}ze", '   ', 'Z' * 100]

      result = renderer.clarify_variant(names)

      expect(result[:attribute_names]).to eq(['Si ze', 'Z' * described_class::MAX_ATTRIBUTE_NAME_LENGTH])
    end
  end

  describe 'catalog / unsupported' do
    it 'renders safe factless descriptors' do
      expect(renderer.catalog_unavailable).to eq(kind: :catalog_unavailable)
      expect(renderer.unsupported).to eq(kind: :unsupported)
    end
  end

  describe 'immutability and allowlist' do
    it 'deeply freezes every descriptor (including nested collections)' do
      result = renderer.clarify_family([{ code: 'FAM-1', name: 'Impeller' }])

      expect(result).to be_frozen
      expect(result[:candidates]).to be_frozen
      expect(result[:candidates].first).to be_frozen
    end

    it 'only ever emits an allowlisted :kind' do
      emitted = [
        renderer.parent_info(code: 'F', name: 'N'),
        renderer.variant_info({ code: 'F', name: 'N' }, 'C'),
        renderer.price_available({ price_list_rate: '1', currency: 'USD', uom: 'Nos' }, 'C'),
        renderer.price_unavailable, renderer.price_conflict,
        renderer.stock_available('C'), renderer.stock_empty('C'), renderer.stock_unavailable,
        renderer.clarify_family([]), renderer.clarify_variant([]),
        renderer.catalog(code: 'F', name: 'N'),
        renderer.catalog_unavailable, renderer.unsupported
      ]

      expect(emitted.map { |d| d[:kind] }.uniq).to all(satisfy { |k| described_class::KINDS.include?(k) })
    end
  end
end
