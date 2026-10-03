# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 3 — the strict, bounded, fail-closed input contract for the Decision
# Runner. These examples pin that only in-bounds, allowlisted, control-clean input is
# accepted; that state is a candidate-only COARSE-HINT allowlist (never a fact/ID/row);
# that scenarios are exact hashes with a stable key + bounded summaries + allowlisted
# capabilities; and that every outbound value is contract-OWNED (the caller's input is
# never mutated or frozen). All product/variant strings are SYNTHETIC candidates.
RSpec.describe Marine::Decision::InputContract do
  let(:invalid) { described_class::Invalid }

  def scenarios
    [
      { 'key' => 'stock_check', 'description' => 'Customer asks about availability', 'instruction' => 'Check stock',
        'capabilities' => %w[stock price] },
      { 'key' => 'catalog_browse', 'description' => 'Customer is browsing', 'instruction' => 'Show catalog', 'capabilities' => %w[catalog] }
    ]
  end

  def build(overrides = {})
    described_class.build(
      message: 'Do you have the Santorini vase in stock?', context: [], state: {}, scenarios: scenarios, **overrides
    )
  end

  describe 'message' do
    it 'accepts and strips a bounded, control-clean message' do
      expect(build(message: "  hello there \n")[:message]).to eq('hello there')
    end

    it 'rejects blank, wrong-type, oversized, and control-heavy messages (never truncates)' do
      expect { build(message: '   ') }.to raise_error(invalid)
      expect { build(message: nil) }.to raise_error(invalid)
      expect { build(message: 123) }.to raise_error(invalid)
      expect { build(message: 'a' * (described_class::MAX_MESSAGE_CHARS + 1)) }.to raise_error(invalid)
      expect { build(message: "hi\u0000there") }.to raise_error(invalid)
    end

    it 'permits tab/newline/carriage-return as legitimate turn whitespace' do
      expect { build(message: "line one\nline two\tindented") }.not_to raise_error
    end
  end

  describe 'context' do
    it 'accepts bounded role/content entries and owns them' do
      context = [{ 'role' => 'user', 'content' => ' Hi ' }, { 'role' => 'assistant', 'content' => 'Hello!' }]
      expect(build(context: context)[:context]).to eq([{ role: 'user', content: 'Hi' }, { role: 'assistant', content: 'Hello!' }])
    end

    it 'rejects unknown keys, unknown roles, blank/oversized content, and too many entries' do
      expect { build(context: [{ 'role' => 'user', 'content' => 'hi', 'extra' => 1 }]) }.to raise_error(invalid)
      expect { build(context: [{ 'role' => 'system', 'content' => 'hi' }]) }.to raise_error(invalid)
      expect { build(context: [{ 'role' => 'user', 'content' => '' }]) }.to raise_error(invalid)
      expect do
        build(context: Array.new(described_class::MAX_CONTEXT_ENTRIES + 1) do
          { 'role' => 'user', 'content' => 'x' }
        end)
      end.to raise_error(invalid)
    end

    it 'rejects a mixed String/Symbol duplicate key' do
      expect { build(context: [{ 'role' => 'user', :role => 'user', 'content' => 'hi' }]) }.to raise_error(invalid)
    end
  end

  describe 'state (coarse candidate hints only)' do
    it 'keeps allowlisted hints and drops blank ones' do
      state = { 'current_scenario' => 'stock_check', 'current_intent' => 'stock', 'awaiting_slot' => 'variant_input',
                'current_product_candidate' => ' Santorini ', 'current_variant_candidate' => '' }
      expect(build(state: state)[:state]).to eq(
        'current_scenario' => 'stock_check', 'current_intent' => 'stock',
        'awaiting_slot' => 'variant_input', 'current_product_candidate' => 'Santorini'
      )
    end

    it 'rejects any key outside the coarse-hint allowlist (no price/stock/quantity/ids/rows/metadata)' do
      %w[price stock quantity validated_variant_code id record metadata warehouse].each do |forbidden|
        expect { build(state: { forbidden => 'x' }) }.to raise_error(invalid)
      end
    end

    it 'rejects invalid hint values' do
      expect { build(state: { 'current_intent' => 'not_an_intent' }) }.to raise_error(invalid)
      expect { build(state: { 'awaiting_slot' => 'nope' }) }.to raise_error(invalid)
      expect { build(state: { 'current_scenario' => 'Not A Key' }) }.to raise_error(invalid)
    end
  end

  describe 'scenarios' do
    it 'requires at least one scenario and rejects an empty/oversized/non-array list' do
      expect { build(scenarios: []) }.to raise_error(invalid)
      expect { build(scenarios: {}) }.to raise_error(invalid)
      expect do
        build(scenarios: Array.new(described_class::MAX_SCENARIOS + 1) do |i|
          { 'key' => "s#{i}", 'description' => 'd', 'instruction' => 'i', 'capabilities' => [] }
        end)
      end.to raise_error(invalid)
    end

    it 'exposes canonical scenario keys and the capability union (incl. unsupported) in Schema order' do
      input = build
      expect(input[:scenario_keys]).to eq(%w[stock_check catalog_browse])
      # union {stock, price, catalog} + unsupported, ordered by Schema::INTENTS.
      expect(input[:allowed_intents]).to eq(%w[price stock catalog unsupported])
    end

    it 'rejects unknown/mixed keys, a non-canonical key, blank summaries, and duplicate scenario keys' do
      expect do
        build(scenarios: [{ 'key' => 'k', 'description' => 'd', 'instruction' => 'i', 'capabilities' => [], 'x' => 1 }])
      end.to raise_error(invalid)
      expect { build(scenarios: [{ 'key' => 'Bad Key', 'description' => 'd', 'instruction' => 'i', 'capabilities' => [] }]) }.to raise_error(invalid)
      expect { build(scenarios: [{ 'key' => 'k', 'description' => '', 'instruction' => 'i', 'capabilities' => [] }]) }.to raise_error(invalid)
      dupes = [{ 'key' => 'k', 'description' => 'd', 'instruction' => 'i', 'capabilities' => [] },
               { 'key' => 'k', 'description' => 'd2', 'instruction' => 'i2', 'capabilities' => [] }]
      expect { build(scenarios: dupes) }.to raise_error(invalid)
    end

    it 'rejects capabilities that are not allowlisted Schema intents, are duplicated, or are inferred by overlap' do
      expect do
        build(scenarios: [{ 'key' => 'k', 'description' => 'd', 'instruction' => 'i', 'capabilities' => %w[not_an_intent] }])
      end.to raise_error(invalid)
      expect do
        build(scenarios: [{ 'key' => 'k', 'description' => 'd', 'instruction' => 'i', 'capabilities' => %w[price price] }])
      end.to raise_error(invalid)
    end
  end

  describe 'hash key type safety (rejects non-String/Symbol keys before canonicalization)' do
    it 'rejects a numeric hash key' do
      expect { build(state: { 1 => 'x' }) }.to raise_error(invalid)
    end

    it 'rejects a malicious custom-object key whose #to_s would forge an allowlisted key' do
      forged = Class.new do
        def to_s
          'current_intent'
        end
      end.new
      expect { build(state: { forged => 'stock' }) }.to raise_error(invalid)
    end
  end

  describe 'caller ownership' do
    it 'never mutates or freezes the caller input' do
      message = +'Do you have stock?'
      context = [{ 'role' => 'user', 'content' => +'hi' }]
      state = { 'current_intent' => 'stock' }
      scens = scenarios
      described_class.build(message: message, context: context, state: state, scenarios: scens)

      expect(message).not_to be_frozen
      expect(context.first).not_to be_frozen
      expect(state).not_to be_frozen
      expect(scens.first).not_to be_frozen
      expect(scens.first['capabilities']).not_to be_frozen
    end
  end
end
