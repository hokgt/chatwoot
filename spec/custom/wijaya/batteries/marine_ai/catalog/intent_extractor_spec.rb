# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::IntentExtractor do
  subject(:extractor) { described_class.new(base_service: base_service) }

  let(:base_service) { instance_double(Marine::Llm::BaseService, configured?: true) }
  let(:captured_prompts) { [] }

  # Every example stubs the LLM: no live model, DB, or repository is ever touched.
  def stub_llm(message:, success: true)
    allow(base_service).to receive(:complete) do |prompt:, system: nil, **options|
      captured_prompts << { prompt: prompt, system: system, options: options }
      { ok: success, message: message, error: success ? nil : 'boom' }
    end
  end

  # The exact, complete set of contract keys — the result must never drift from it.
  CONTRACT_KEYS = %i[
    product_related intent requested_intents family_mention explicit_child_code attribute_candidates
    requires_exact_variant clarification_reply family_changed intent_changed intent_scope
    multiple_numeric_candidates quantity_inquiry unsupported_request confidence customer_language reason
  ].freeze

  def extract(text: 'hello', context: nil, state: nil)
    extractor.extract(text: text, context: context, state: state)
  end

  # Build a product-related LLM payload as JSON, keeping example lines compact.
  def llm_json(**fields)
    { 'product_related' => true }.merge(fields.transform_keys(&:to_s)).to_json
  end

  describe 'output contract' do
    it 'always returns exactly the allowlisted contract keys and no others' do
      stub_llm(message: '{"product_related": true, "intent": "price", "evil_key": "drop me"}')

      result = extract

      expect(result.keys).to match_array(CONTRACT_KEYS)
      expect(result).not_to have_key(:evil_key)
    end
  end

  describe 'supported intents' do
    %w[price stock parent_info variant_info catalog].each do |intent|
      it "passes through the #{intent} intent" do
        stub_llm(message: %({"product_related": true, "intent": "#{intent}"}))

        result = extract

        expect(result[:product_related]).to be(true)
        expect(result[:intent]).to eq(intent)
        expect(result[:reason]).to eq('extracted')
      end
    end
  end

  describe 'non-product messages' do
    it 'classifies a non-product message without a product intent' do
      stub_llm(message: '{"product_related": false, "intent": "unsupported"}')

      result = extract(text: 'What are your opening hours?')

      expect(result[:product_related]).to be(false)
      expect(result[:reason]).to eq('not_product')
    end
  end

  describe 'numbers are never automatically codes' do
    it 'ignores a quantity number' do
      stub_llm(message: '{"product_related": true, "intent": "price", "attribute_candidates": ["5 units"]}')

      result = extract(text: 'I need 5 of the bilge pump')

      expect(result[:explicit_child_code]).to be_nil
      expect(result[:multiple_numeric_candidates]).to be(false)
    end

    it 'does not promote a lone price number to a code' do
      stub_llm(message: '{"product_related": true, "intent": "price"}')

      result = extract(text: 'is it around 250 dollars?')

      expect(result[:explicit_child_code]).to be_nil
    end

    it 'does not promote a lone size number to a code' do
      stub_llm(message: '{"product_related": true, "intent": "variant_info", "attribute_candidates": ["12 inch"]}')

      result = extract(text: 'do you have the 12 inch one')

      expect(result[:explicit_child_code]).to be_nil
      expect(result[:attribute_candidates]).to eq(['12 inch'])
    end

    it 'discards a numeric explicit_child_code when the system is NOT awaiting a code' do
      stub_llm(message: llm_json(intent: 'variant_info', explicit_child_code: '1000', explicit_child_code_from_context: true))

      result = extract(text: '1000', state: { awaiting_code: false })

      expect(result[:explicit_child_code]).to be_nil
    end

    it 'discards a numeric explicit_child_code when the LLM gives no contextual evidence' do
      stub_llm(message: llm_json(intent: 'variant_info', explicit_child_code: '1000', explicit_child_code_from_context: false))

      result = extract(text: '1000', state: { awaiting_code: true })

      expect(result[:explicit_child_code]).to be_nil
    end

    it 'accepts a single numeric code only when awaiting a code AND the LLM flags context' do
      stub_llm(message: llm_json(intent: 'variant_info', explicit_child_code: '1000', explicit_child_code_from_context: true))

      result = extract(text: '1000', state: { awaiting_code: true })

      expect(result[:explicit_child_code]).to eq('1000')
    end

    it 'keeps an alphanumeric candidate code without any state gating' do
      stub_llm(message: '{"product_related": true, "intent": "variant_info", "explicit_child_code": "PMP-1000A"}')

      result = extract(text: 'the PMP-1000A please')

      expect(result[:explicit_child_code]).to eq('PMP-1000A')
    end

    it 'discards a decimal numeric-only code outside the safe contextual gate' do
      stub_llm(message: llm_json(intent: 'variant_info', explicit_child_code: '12.5', explicit_child_code_from_context: true))

      result = extract(text: '12.5', state: { awaiting_code: false })

      expect(result[:explicit_child_code]).to be_nil
    end

    it 'discards a thousands-formatted numeric-only code outside the safe contextual gate' do
      stub_llm(message: llm_json(intent: 'variant_info', explicit_child_code: '1,000', explicit_child_code_from_context: false))

      result = extract(text: '1,000', state: { awaiting_code: true })

      expect(result[:explicit_child_code]).to be_nil
    end

    it 'discards a signed numeric-only code outside the safe contextual gate' do
      stub_llm(message: llm_json(intent: 'variant_info', explicit_child_code: '-123', explicit_child_code_from_context: true))

      result = extract(text: '-123', state: { awaiting_code: false })

      expect(result[:explicit_child_code]).to be_nil
    end

    it 'accepts a decimal numeric-only code only when awaiting a code AND the LLM flags context' do
      stub_llm(message: llm_json(intent: 'variant_info', explicit_child_code: '12.5', explicit_child_code_from_context: true))

      result = extract(text: '12.5', state: { awaiting_code: true })

      expect(result[:multiple_numeric_candidates]).to be(false)
      expect(result[:explicit_child_code]).to eq('12.5')
    end
  end

  describe 'quantity_inquiry mapping (bounded untrusted boolean)' do
    it 'maps an explicit true through to the contract flag' do
      stub_llm(message: llm_json(intent: 'stock', quantity_inquiry: true))

      expect(extract(text: 'how many units do you have on hand?')[:quantity_inquiry]).to be(true)
    end

    it 'maps a common truthy string encoding to true' do
      stub_llm(message: llm_json(intent: 'stock', quantity_inquiry: 'yes'))

      expect(extract[:quantity_inquiry]).to be(true)
    end

    it 'defaults a missing quantity_inquiry to false' do
      stub_llm(message: llm_json(intent: 'stock'))

      expect(extract(text: 'is the impeller in stock?')[:quantity_inquiry]).to be(false)
    end

    it 'coerces a malformed/non-boolean quantity_inquiry to false' do
      stub_llm(message: llm_json(intent: 'stock', quantity_inquiry: 'sure maybe'))

      expect(extract[:quantity_inquiry]).to be(false)
    end
  end

  describe 'deterministic classification' do
    it 'requests the provider at temperature 0 so a borderline answer-shape does not flip between runs' do
      stub_llm(message: llm_json(intent: 'stock'))

      extract

      expect(captured_prompts.last[:options]).to include(temperature: 0)
    end
  end

  describe 'stock answer-shape → exact-quantity derivation (structured answer shape)' do
    it 'normalizes an exact_count answer shape to quantity_inquiry true even when the boolean is absent' do
      stub_llm(message: llm_json(intent: 'stock', stock_answer_shape: 'exact_count'))

      expect(extract(text: 'how many units are on hand?')[:quantity_inquiry]).to be(true)
    end

    it 'tags unsupported_request exact_quantity for an exact_count answer shape' do
      stub_llm(message: llm_json(intent: 'stock', stock_answer_shape: 'exact_count'))

      expect(extract[:unsupported_request]).to eq('exact_quantity')
    end

    it 'keeps a plain availability answer shape binary (quantity_inquiry false, category nil)' do
      stub_llm(message: llm_json(intent: 'stock', stock_answer_shape: 'availability'))

      result = extract(text: 'is it available?')
      expect(result[:quantity_inquiry]).to be(false)
      expect(result[:unsupported_request]).to be_nil
    end

    it 'normalizes case/whitespace on the answer shape before matching the allowlist' do
      stub_llm(message: llm_json(intent: 'stock', stock_answer_shape: '  Exact_Count '))

      expect(extract[:quantity_inquiry]).to be(true)
    end

    it 'treats a missing answer shape as no exact-count signal (defaults to false)' do
      stub_llm(message: llm_json(intent: 'stock'))

      expect(extract(text: 'is the impeller in stock?')[:quantity_inquiry]).to be(false)
    end

    it 'treats an unknown/malformed answer shape as no exact-count signal (fail closed to false)' do
      stub_llm(message: llm_json(intent: 'stock', stock_answer_shape: 'give_me_everything'))

      result = extract
      expect(result[:quantity_inquiry]).to be(false)
      expect(result[:unsupported_request]).to be_nil
    end

    it 'drops a type-confused non-string answer shape (no exact-count signal)' do
      stub_llm(message: '{"product_related": true, "intent": "stock", "stock_answer_shape": ["exact_count"]}')

      expect(extract[:quantity_inquiry]).to be(false)
    end

    it 'preserves legacy quantity_inquiry:true compatibility (no answer shape supplied)' do
      stub_llm(message: llm_json(intent: 'stock', quantity_inquiry: true))

      result = extract(text: 'how many do you have?')
      expect(result[:quantity_inquiry]).to be(true)
      expect(result[:unsupported_request]).to eq('exact_quantity')
    end

    it 'lets the exact_count answer shape win when the boolean conflicts (says false)' do
      stub_llm(message: llm_json(intent: 'stock', quantity_inquiry: false, stock_answer_shape: 'exact_count'))

      expect(extract[:quantity_inquiry]).to be(true)
    end

    it 'never lets an availability answer shape override a legacy quantity_inquiry true' do
      stub_llm(message: llm_json(intent: 'stock', quantity_inquiry: true, stock_answer_shape: 'availability'))

      result = extract
      expect(result[:quantity_inquiry]).to be(true)
      expect(result[:unsupported_request]).to eq('exact_quantity')
    end

    it 'lets a quantity inquiry override a conflicting provider-supplied unsupported_request category' do
      stub_llm(message: llm_json(intent: 'stock', stock_answer_shape: 'exact_count', unsupported_request: 'shipping_cost'))

      expect(extract[:unsupported_request]).to eq('exact_quantity')
    end
  end

  describe 'intent_scope continuation classifier (bounded slot-vs-switch signal)' do
    it 'passes through a slot_value scope while awaiting a code (candidate-only answer)' do
      stub_llm(message: llm_json(intent: 'variant_info', explicit_child_code: 'BD-1', intent_scope: 'slot_value'))

      result = extract(text: 'varian warna BD-1', state: { awaiting_code: true, current_intent: 'stock' })
      expect(result[:intent_scope]).to eq('slot_value')
    end

    it 'passes through a new_intent scope for an explicit switch that also names a candidate' do
      stub_llm(message: llm_json(intent: 'price', explicit_child_code: 'BD-1', intent_scope: 'new_intent'))

      result = extract(text: 'actually what is the price of BD-1', state: { awaiting_code: true, current_intent: 'stock' })
      expect(result[:intent_scope]).to eq('new_intent')
    end

    it 'normalizes case/whitespace before matching the scope allowlist' do
      stub_llm(message: llm_json(intent: 'variant_info', intent_scope: '  Slot_Value '))

      expect(extract[:intent_scope]).to eq('slot_value')
    end

    it 'fails closed to nil on a missing scope' do
      stub_llm(message: llm_json(intent: 'variant_info'))

      expect(extract[:intent_scope]).to be_nil
    end

    it 'fails closed to nil on an unknown/malformed scope' do
      stub_llm(message: llm_json(intent: 'variant_info', intent_scope: 'maybe_switch'))

      expect(extract[:intent_scope]).to be_nil
    end

    it 'drops a type-confused non-string scope (nil)' do
      stub_llm(message: '{"product_related": true, "intent": "variant_info", "intent_scope": ["slot_value"]}')

      expect(extract[:intent_scope]).to be_nil
    end

    it 'defaults to nil on the safe unknown result when the LLM fails' do
      stub_llm(message: 'not json', success: true)

      expect(extract[:intent_scope]).to be_nil
    end

    it 'establishes the slot-vs-switch contract in the system prompt (allowlisted values, no keyword list)' do
      stub_llm(message: llm_json(intent: 'variant_info'))

      extract(state: { awaiting_code: true, current_intent: 'stock' })

      system = captured_prompts.last[:system]
      expect(system).to include('intent_scope')
      expect(system).to include('slot_value')
      expect(system).to include('new_intent')
    end
  end

  describe 'unsupported_request category mapping (bounded generic allowlist)' do
    Marine::Catalog::IntentExtractor::UNSUPPORTED_REQUEST_CATEGORIES.each do |category|
      it "maps the allowlisted #{category} category through unchanged" do
        stub_llm(message: llm_json(intent: 'unsupported', unsupported_request: category))

        expect(extract[:unsupported_request]).to eq(category)
      end
    end

    it 'normalizes case/whitespace to the allowlisted value' do
      stub_llm(message: llm_json(intent: 'unsupported', unsupported_request: '  Delivery_Feasibility '))

      expect(extract[:unsupported_request]).to eq('delivery_feasibility')
    end

    it 'defaults a missing category to nil' do
      stub_llm(message: llm_json(intent: 'price'))

      expect(extract[:unsupported_request]).to be_nil
    end

    it 'rejects an unknown/malformed category to nil (never a fabricated bucket)' do
      stub_llm(message: llm_json(intent: 'unsupported', unsupported_request: 'wire_me_money'))

      expect(extract[:unsupported_request]).to be_nil
    end

    it 'drops a type-confused non-string category to nil' do
      stub_llm(message: '{"product_related": true, "intent": "unsupported", "unsupported_request": ["delivery_feasibility"]}')

      expect(extract[:unsupported_request]).to be_nil
    end
  end

  describe 'multiple numeric candidates' do
    it 'sets the ambiguity marker and refuses to promote any number to a code' do
      stub_llm(message: llm_json(intent: 'variant_info', explicit_child_code: '1000', explicit_child_code_from_context: true))

      result = extract(text: 'I saw 1000 and 2000, which fits?', state: { awaiting_code: true })

      expect(result[:multiple_numeric_candidates]).to be(true)
      expect(result[:explicit_child_code]).to be_nil
    end
  end

  describe 'family and intent switches' do
    it 'flags a family change against the safe state' do
      stub_llm(message: '{"product_related": true, "intent": "price", "family_mention": "Bilge Pump"}')

      result = extract(state: { current_family: 'Anchor Winch' })

      expect(result[:family_mention]).to eq('Bilge Pump')
      expect(result[:family_changed]).to be(true)
    end

    it 'does not flag a family change when the mention matches the current family' do
      stub_llm(message: '{"product_related": true, "intent": "price", "family_mention": "Bilge Pump"}')

      result = extract(state: { current_family: 'Bilge Pump' })

      expect(result[:family_changed]).to be(false)
    end

    it 'flags an intent change against the safe state' do
      stub_llm(message: '{"product_related": true, "intent": "stock"}')

      result = extract(state: { current_intent: 'price' })

      expect(result[:intent_changed]).to be(true)
    end
  end

  describe 'LLM failure modes collapse to a safe unknown result' do
    it 'returns unknown when the Marine LLM is unconfigured' do
      allow(base_service).to receive(:configured?).and_return(false)
      expect(base_service).not_to receive(:complete)

      result = extract

      expect(result[:intent]).to eq('unknown')
      expect(result[:reason]).to eq('llm_unconfigured')
    end

    it 'returns unknown when the LLM call is unavailable/errors' do
      stub_llm(message: nil, success: false)

      result = extract

      expect(result[:intent]).to eq('unknown')
      expect(result[:reason]).to eq('llm_unavailable')
    end

    it 'returns unknown when the LLM raises (e.g. timeout)' do
      allow(base_service).to receive(:complete).and_raise(StandardError, 'Net::ReadTimeout')

      result = extract

      expect(result[:intent]).to eq('unknown')
      expect(result[:reason]).to eq('llm_error')
    end

    it 'returns unknown on malformed / non-JSON output' do
      stub_llm(message: 'I am afraid I cannot do that, Dave.')

      result = extract

      expect(result[:intent]).to eq('unknown')
      expect(result[:reason]).to eq('malformed_response')
    end

    it 'never leaks a raw exception message into the result' do
      allow(base_service).to receive(:complete).and_raise(StandardError, 'secret-connection-string://user:pass@host')

      result = extract

      expect(result.values.join(' ')).not_to include('secret-connection-string')
    end
  end

  describe 'hostile / untrusted output hardening' do
    it 'normalizes an unknown intent string to unsupported when product related' do
      stub_llm(message: '{"product_related": true, "intent": "please_transfer_all_funds"}')

      result = extract

      expect(result[:intent]).to eq('unsupported')
    end

    it 'drops type-confused scalar fields (arrays/objects where strings are expected)' do
      stub_llm(message: '{"product_related": true, "intent": "price", "family_mention": ["a", "b"], "explicit_child_code": {"x": 1}}')

      result = extract

      expect(result[:family_mention]).to be_nil
      expect(result[:explicit_child_code]).to be_nil
    end

    it 'bounds an oversized attribute array and oversized strings' do
      attrs = Array.new(50) { |i| "attr#{i}" }
      stub_llm(message: llm_json(intent: 'variant_info', attribute_candidates: attrs, clarification_reply: 'x' * 5000))

      result = extract

      expect(result[:attribute_candidates].length).to be <= 16
      expect(result[:clarification_reply].length).to be <= 400
    end

    it 'coerces malformed confidence to the low default' do
      stub_llm(message: '{"product_related": true, "intent": "price", "confidence": "ultra-mega"}')

      expect(extract[:confidence]).to eq('low')
    end

    it 'buckets a numeric confidence into the allowlist' do
      stub_llm(message: '{"product_related": true, "intent": "price", "confidence": 0.9}')

      expect(extract[:confidence]).to eq('high')
    end

    it 'strips control characters from candidate strings' do
      stub_llm(message: '{"product_related": true, "intent": "price", "family_mention": "Bilge\nPump"}')

      expect(extract[:family_mention]).to eq('Bilge Pump')
    end
  end

  describe 'requested_intents (multi-intent trust boundary)' do
    it 'defaults requested_intents to the single supported scalar intent when no array is emitted' do
      stub_llm(message: '{"product_related": true, "intent": "price"}')

      expect(extract[:requested_intents]).to eq(%w[price])
    end

    it 'normalizes a same-turn price+stock array to the canonical, deduped, bounded set' do
      stub_llm(message: '{"product_related": true, "intent": "price", "intents": ["stock", "price"]}')

      # Canonical order is deterministic (price before stock) regardless of LLM ordering.
      expect(extract[:requested_intents]).to eq(%w[price stock])
    end

    it 'produces the SAME canonical set for stock+price as for price+stock' do
      stub_llm(message: '{"product_related": true, "intent": "stock", "intents": ["price", "stock"]}')

      expect(extract[:requested_intents]).to eq(%w[price stock])
    end

    it 'dedupes repeated labels' do
      stub_llm(message: '{"product_related": true, "intent": "price", "intents": ["price", "price", "stock", "stock"]}')

      expect(extract[:requested_intents]).to eq(%w[price stock])
    end

    it 'drops unknown / unsupported entries and keeps only the supported product intents' do
      stub_llm(message: '{"product_related": true, "intent": "price", "intents": ["price", "please_wire_funds", "stock", 42, null]}')

      expect(extract[:requested_intents]).to eq(%w[price stock])
    end

    it 'bounds an oversized intents array' do
      stub_llm(message: llm_json(intent: 'price', intents: Array.new(50) { 'price' } + Array.new(50) { 'stock' }))

      expect(extract[:requested_intents].length).to be <= 4
      expect(extract[:requested_intents]).to eq(%w[price stock])
    end

    it 'is empty for a non-product / unknown turn' do
      stub_llm(message: '{"product_related": false}')

      expect(extract[:requested_intents]).to eq([])
    end

    it 'is empty on a failed extraction (unknown result)' do
      allow(base_service).to receive(:configured?).and_return(false)

      expect(extract[:requested_intents]).to eq([])
    end
  end

  describe 'no side effects, no repository selection, no SQL' do
    before { stub_llm(message: '{"product_related": true, "intent": "price", "family_mention": "Bilge Pump", "explicit_child_code": "PMP-1"}') }

    it 'never touches the catalog connection or Phase 1 repositories' do
      expect(Marine::Catalog::Connection).not_to receive(:select)
      expect(Marine::Catalog::ProductFamilyRepository).not_to receive(:new)
      expect(Marine::Catalog::VariantRepository).not_to receive(:new)
      expect(Marine::Catalog::PriceRepository).not_to receive(:new)
      expect(Marine::Catalog::StockRepository).not_to receive(:new)

      extract(state: { current_family: 'Anchor Winch' })
    end

    it 'keeps credentials, DB metadata, prices, and stock numbers out of the prompt' do
      extract

      sent = captured_prompts.last
      combined = "#{sent[:prompt]} #{sent[:system]}"
      expect(combined).not_to match(/password|api_key|marine_ai\.item|SELECT|postgres/i)
    end
  end
end
