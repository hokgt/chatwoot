# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the PURE, privacy-safe projection of an IntentExtractor-shaped product-intent Hash into
# the SINGLE closed { status, intents, slot_ops, requires_exact_variant, quantity_inquiry } outcome the
# product shadow compares/scores. These examples pin: a non-Hash / non-product input folds to the safe
# unknown/not_product outcome; status/intent/slot vocabularies stay closed and canonically ordered; a
# raw candidate slot value collapses to the mere presence of a typed slot operation; and every result
# is frozen. No provider/settings/Redis access is possible (pure module). All inputs are SYNTHETIC.
RSpec.describe Marine::ProductAuthority::ProductOutcome do
  describe '.project — safe folds' do
    it 'folds nil / a non-Hash input to the frozen unknown outcome' do
      [nil, 'nope', 42, [], :sym].each do |bad|
        result = described_class.project(bad)
        expect(result).to eq(described_class.unknown)
        expect(result).to be_frozen
      end
    end

    it 'folds an explicitly non-product turn to not_product' do
      [{}, { product_related: false }, { product_related: nil }].each do |input|
        result = described_class.project(input)
        expect(result[:status]).to eq('not_product')
        expect(result).to eq(described_class.not_product_outcome)
        expect(result).to be_frozen
      end
    end
  end

  describe '.project — status vocabulary' do
    it 'projects a supported transactional intent to product' do
      result = described_class.project(product_related: true, intent: 'price', requested_intents: ['price'],
                                       family_mention: 'Some Family', explicit_child_code: 'ABC-1')
      expect(result[:status]).to eq('product')
      expect(result[:intents]).to eq(['price'])
      expect(result[:slot_ops]).to eq(%w[product variant_code])
      expect(result).to be_frozen
    end

    it 'projects product_overview to overview' do
      result = described_class.project(product_related: true, intent: 'product_overview')
      expect(result[:status]).to eq('overview')
      expect(result[:intents]).to eq(['product_overview'])
    end

    it 'projects an unsupported intent OR an unsupported_request flag to unsupported (with no intents)' do
      by_intent = described_class.project(product_related: true, intent: 'unsupported', requested_intents: ['unsupported'])
      by_flag = described_class.project(product_related: true, intent: 'price', unsupported_request: true)
      expect(by_intent[:status]).to eq('unsupported')
      expect(by_intent[:intents]).to eq([])
      expect(by_flag[:status]).to eq('unsupported')
    end

    it 'projects a product turn with an unknown scalar intent to unknown' do
      result = described_class.project(product_related: true, intent: 'teleport')
      expect(result[:status]).to eq('unknown')
      expect(result[:intents]).to eq([])
    end
  end

  describe '.project — slot operations from presence only' do
    it 'emits product for a present family mention only' do
      result = described_class.project(product_related: true, intent: 'price', family_mention: 'Widget')
      expect(result[:slot_ops]).to eq(['product'])
    end

    it 'emits variant_code for a present explicit child code only' do
      result = described_class.project(product_related: true, intent: 'price', explicit_child_code: 'ABC-1')
      expect(result[:slot_ops]).to eq(['variant_code'])
    end

    it 'emits variant_attr for a non-empty attribute candidate array only' do
      result = described_class.project(product_related: true, intent: 'price', attribute_candidates: ['red'])
      expect(result[:slot_ops]).to eq(['variant_attr'])
    end

    it 'ignores blank / non-string / empty candidate content (presence only)' do
      result = described_class.project(product_related: true, intent: 'price',
                                       family_mention: '   ', explicit_child_code: '', attribute_candidates: [])
      expect(result[:slot_ops]).to eq([])
    end

    it 'renders all present slot operations in canonical order' do
      result = described_class.project(product_related: true, intent: 'price',
                                       family_mention: 'F', explicit_child_code: 'C', attribute_candidates: ['x'])
      expect(result[:slot_ops]).to eq(%w[product variant_code variant_attr])
    end
  end

  describe '.project — intents and flags' do
    it 'dedupes and canonically orders the requested + primary intents' do
      result = described_class.project(product_related: true, intent: 'price',
                                       requested_intents: %w[stock price price catalog])
      expect(result[:intents]).to eq(%w[price stock catalog])
    end

    it 'carries the quantity_inquiry and requires_exact_variant boolean flags' do
      result = described_class.project(product_related: true, intent: 'stock',
                                       quantity_inquiry: true, requires_exact_variant: true)
      expect(result[:quantity_inquiry]).to be(true)
      expect(result[:requires_exact_variant]).to be(true)
    end

    it 'coerces a non-true flag value to false' do
      result = described_class.project(product_related: true, intent: 'stock',
                                       quantity_inquiry: 'yes', requires_exact_variant: 1)
      expect(result[:quantity_inquiry]).to be(false)
      expect(result[:requires_exact_variant]).to be(false)
    end
  end

  describe '.unknown / .blocked / .not_product_outcome' do
    it 'are the frozen empty-shaped safe outcomes' do
      expect(described_class.unknown).to eq(status: 'unknown', intents: [], slot_ops: [],
                                            requires_exact_variant: false, quantity_inquiry: false)
      expect(described_class.blocked[:status]).to eq('blocked')
      expect(described_class.not_product_outcome[:status]).to eq('not_product')
      expect([described_class.unknown, described_class.blocked, described_class.not_product_outcome]).to all(be_frozen)
    end
  end

  describe '.compare' do
    def outcome(status:, intents:, slot_ops:)
      { status: status, intents: intents, slot_ops: slot_ops, requires_exact_variant: false, quantity_inquiry: false }
    end

    it 'reports exact_match when status, intents, and slot_ops all agree' do
      a = outcome(status: 'product', intents: %w[price], slot_ops: %w[product])
      result = described_class.compare(a, a.dup)
      expect(result).to eq(intents_match: true, slots_match: true, status_match: true, exact_match: true)
      expect(result).to be_frozen
    end

    it 'reports the per-field disagreement and no exact match when any field differs' do
      legacy = outcome(status: 'product', intents: %w[price], slot_ops: %w[product])
      candidate = outcome(status: 'unsupported', intents: %w[stock], slot_ops: %w[variant_code])
      result = described_class.compare(legacy, candidate)
      expect(result).to eq(intents_match: false, slots_match: false, status_match: false, exact_match: false)
    end

    it 'reports a partial match (status agrees, intents differ) as not exact' do
      legacy = outcome(status: 'product', intents: %w[price], slot_ops: %w[product])
      candidate = outcome(status: 'product', intents: %w[stock], slot_ops: %w[product])
      result = described_class.compare(legacy, candidate)
      expect(result).to include(status_match: true, slots_match: true, intents_match: false, exact_match: false)
    end
  end
end
