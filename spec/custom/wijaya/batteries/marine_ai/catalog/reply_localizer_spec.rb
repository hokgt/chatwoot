# frozen_string_literal: true

require 'rails_helper'

# ReplyLocalizer translates a deterministic English product reply into the customer's language,
# then GATES the untrusted translation on factual safety: a deterministic generic token-inventory
# check, the deterministic ProductFactProtectionValidator (for a supported descriptor), and a
# separate semantic FactPreservationValidator. Any failure/uncertainty fails CLOSED to the exact
# English source. English/unknown/unconfigured/unchanged paths never invoke a validator.
RSpec.describe Marine::Catalog::ReplyLocalizer do
  # Generic fake reply text — never a real product name or a language-specific phrase map.
  let(:english_text) { 'Here is the product catalog for Widget Base.' }

  def detector_for(language)
    instance_double(Marine::Llm::LanguageDetector, detect: { language: language, reliable: true, confidence: 1.0 })
  end

  def stub_translation(text)
    translator = instance_double(Marine::Llm::TranslateResponseService, call: { ok: true, text: text, translated: true })
    allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(translator)
    translator
  end

  # The separate semantic validator is an LLM call; stub it so the deterministic gates are what
  # the example actually exercises. Returns the double so examples can assert it was/wasn't called.
  def stub_semantic(accepted)
    validator = instance_double(Marine::Charge::FactPreservationValidator, valid?: accepted)
    allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)
    validator
  end

  def localize(text: english_text, trigger: 'mau lihat katalog', provider_language: nil, action: nil, descriptor: nil)
    described_class.new(text: text, trigger_text: trigger, provider_language: provider_language,
                        action: action, descriptor: descriptor).call
  end

  describe 'language selection (unchanged, never invokes a validator)' do
    it 'leaves an English (source-language) reply untouched and never translates or validates' do
      allow(Marine::Llm::LanguageDetector).to receive(:new).with('do you have the catalog').and_return(detector_for('en'))
      expect(Marine::Llm::TranslateResponseService).not_to receive(:new)
      expect(Marine::Charge::FactPreservationValidator).not_to receive(:new)

      expect(localize(trigger: 'do you have the catalog')).to eq(english_text)
    end

    it 'returns the original text when neither the trigger nor context yields a language' do
      allow(Marine::Llm::LanguageDetector).to receive(:new).with('hi').and_return(detector_for('unknown'))
      allow(Marine::Llm::LanguageDetector).to receive(:new).with('hello').and_return(detector_for('unknown'))
      expect(Marine::Llm::TranslateResponseService).not_to receive(:new)

      result = described_class.new(text: english_text, trigger_text: 'hi', context: ['hello']).call
      expect(result).to eq(english_text)
    end

    it 'returns blank text without detecting, translating, or validating' do
      expect(Marine::Llm::LanguageDetector).not_to receive(:new)
      expect(Marine::Llm::TranslateResponseService).not_to receive(:new)
      expect(Marine::Charge::FactPreservationValidator).not_to receive(:new)

      expect(localize(text: '   ')).to eq('   ')
    end

    it 'degrades to English when the translator returns it unchanged, without validating' do
      allow(Marine::Llm::LanguageDetector).to receive(:new).and_return(detector_for('id'))
      stub_translation(english_text) # translator degraded on skip/failure -> original English
      expect(Marine::Charge::FactPreservationValidator).not_to receive(:new)

      expect(localize(trigger: 'halo')).to eq(english_text)
    end

    it 'prefers the bounded provider language over local detection and never consults CLD3' do
      expect(Marine::Llm::LanguageDetector).not_to receive(:new)
      stub_translation('Ini katalog produk untuk Widget Base.')
      stub_semantic(true)

      expect(localize(provider_language: 'id')).to eq('Ini katalog produk untuk Widget Base.')
    end
  end

  describe 'factual-safety gate over an untrusted translation' do
    before { allow(Marine::Llm::LanguageDetector).to receive(:new).and_return(detector_for('id')) }

    it 'delivers a faithful translation once every gate accepts it' do
      stub_translation('Ini katalog produk untuk Widget Base.')
      validator = stub_semantic(true)

      expect(localize).to eq('Ini katalog produk untuk Widget Base.')
      expect(validator).to have_received(:valid?).with(approved_answer: english_text, candidate: 'Ini katalog produk untuk Widget Base.')
    end

    it 'rejects a translation that injects a new number back to English before the semantic call' do
      stub_translation('Ini katalog produk untuk Widget Base, 5 tersedia.')
      validator = stub_semantic(true)

      expect(localize).to eq(english_text)
      expect(validator).not_to have_received(:valid?)
    end

    it 'rejects a translation that changes a currency symbol or code token, back to English' do
      priced = 'The price for IMP-3 is IDR 150000 per pcs.'
      stub_translation('Harga untuk IMP-3 adalah USD 150000 per pcs.') # IDR -> USD
      validator = stub_semantic(true)

      expect(localize(text: priced)).to eq(priced)
      expect(validator).not_to have_received(:valid?)
    end

    it 'delivers a faithful price translation preserving every protected token when the descriptor gate passes' do
      priced = 'The price for IMP-3 is IDR 150000 per pcs.'
      descriptor = { kind: :price_available, variant_code: 'IMP-3', price_list_rate: '150000', currency: 'IDR', uom: 'pcs' }
      stub_translation('Harga untuk IMP-3 adalah IDR 150000 per pcs.')
      stub_semantic(true)

      expect(localize(text: priced, action: :reply, descriptor: descriptor)).to eq('Harga untuk IMP-3 adalah IDR 150000 per pcs.')
    end

    it 'rejects a translation that changes a protected display value even when token inventory matches' do
      descriptor = { kind: :catalog, family_code: 'IMP', family_name: 'Impeller' }
      caption = 'Here is the product catalog for Impeller.'
      stub_translation('Ini katalog produk untuk Propeller.') # family display changed; no numeric/code tokens either side
      validator = stub_semantic(true)

      expect(localize(text: caption, action: :send_catalog, descriptor: descriptor)).to eq(caption)
      expect(validator).not_to have_received(:valid?) # deterministic descriptor gate rejects before the semantic call
    end

    it 'rejects a token-clean translation when the separate semantic validator is not certain' do
      stub_translation('Ini katalog produk untuk Widget Base.')
      stub_semantic(false)

      expect(localize).to eq(english_text)
    end

    it 'fails closed to English when the semantic validator raises' do
      stub_translation('Ini katalog produk untuk Widget Base.')
      validator = instance_double(Marine::Charge::FactPreservationValidator)
      allow(validator).to receive(:valid?).and_raise(StandardError, 'boom')
      allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)

      expect(localize).to eq(english_text)
    end
  end

  # Regression — the assistant's configured operating language anchors the target when the
  # authoritative per-turn provider language is absent, so a CLD3 misclassification of a short
  # customer turn (e.g. a brief Indonesian message confidently detected as Hindi-Latn) can no
  # longer drive a wrong-language rewrite (or a robotic English fall-back). Generic and
  # data-driven: no language/phrase is hardcoded; the configured code is supplied by the caller.
  describe 'configured-language fallback (provider language absent)' do
    before do
      # CLD3 confidently MISCLASSIFIES the short Indonesian trigger as Hindi-Latn.
      allow(Marine::Llm::LanguageDetector).to receive(:new).and_return(detector_for('hi-latn'))
    end

    # Capture the target language the localizer asks the translator to render into.
    def captured_target(**)
      target = nil
      translator = instance_double(Marine::Llm::TranslateResponseService, call: { ok: true, text: 'x', translated: true })
      allow(Marine::Llm::TranslateResponseService).to receive(:new) do |args|
        target = args[:target_language]
        translator
      end
      stub_semantic(true)
      described_class.new(text: english_text, trigger_text: 'kirim katalog', **).call
      target
    end

    it 'targets the configured language, not the CLD3 misclassification, when the provider language is absent' do
      expect(captured_target(provider_language: nil, fallback_language: 'id')).to eq('id')
    end

    it 'still prefers the per-turn provider language over the configured fallback' do
      expect(captured_target(provider_language: 'de', fallback_language: 'id')).to eq('de')
    end

    it 'ignores a malformed configured language and falls through to detection' do
      expect(captured_target(provider_language: nil, fallback_language: 'not a code')).to eq('hi-latn')
    end

    it 'trusts the CLD3 result only when no configured language exists (the pre-fix hazard)' do
      expect(captured_target(provider_language: nil, fallback_language: nil)).to eq('hi-latn')
    end
  end
end
