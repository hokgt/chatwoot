# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::IntentExtractor do
  subject(:extractor) { described_class.new(base_service: base_service) }

  let(:base_service) { instance_double(Marine::Llm::BaseService, configured?: true) }
  let(:captured_prompts) { [] }

  # Every example stubs the LLM: no live model, DB, or repository is ever touched.
  def stub_llm(message:, success: true)
    allow(base_service).to receive(:complete) do |prompt:, system: nil|
      captured_prompts << { prompt: prompt, system: system }
      { ok: success, message: message, error: success ? nil : 'boom' }
    end
  end

  # The exact, complete set of contract keys — the result must never drift from it.
  CONTRACT_KEYS = %i[
    product_related intent family_mention explicit_child_code attribute_candidates
    requires_exact_variant clarification_reply family_changed intent_changed
    multiple_numeric_candidates confidence customer_language reason
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
