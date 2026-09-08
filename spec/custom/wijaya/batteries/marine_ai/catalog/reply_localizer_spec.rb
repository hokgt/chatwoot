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

  # D7: the localizer passes the MASKED text (immutable facts replaced by opaque placeholders) to
  # the translator. This stub operates on THAT masked text, rephrasing prose via `transform` while
  # leaving the placeholders verbatim — exactly what a faithful translator does. Corruption tests
  # use `transform` to drop, duplicate, inject, or malform a placeholder or fact.
  def stub_masking_translation(&block)
    allow(Marine::Llm::TranslateResponseService).to receive(:new) do |**kwargs|
      # This receive-block runs LATER (when the localizer translates), so `yield`/anonymous block
      # would be out of scope; the captured named block must be called explicitly.
      instance_double(Marine::Llm::TranslateResponseService,
                      call: { ok: true, text: block.call(kwargs[:text]), translated: true }) # rubocop:disable Performance/RedundantBlockCall
    end
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

    it 'delivers a faithful price translation with every immutable fact restored byte-exact' do
      priced = 'The price for IMP-3 is IDR 150000 per pcs.'
      descriptor = { kind: :price_available, variant_code: 'IMP-3', price_list_rate: '150000', currency: 'IDR', uom: 'pcs' }
      # The translator only ever sees placeholders for the facts; it rephrases prose and they are restored.
      stub_masking_translation { |masked| masked.gsub('The price for', 'Harga untuk').gsub(' is ', ' adalah ') }
      stub_semantic(true)

      expect(localize(text: priced, action: :reply, descriptor: descriptor)).to eq('Harga untuk IMP-3 adalah IDR 150000 per pcs.')
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

  # D7 — configured-language consistency with placeholder-protected facts. Immutable facts (codes,
  # currency, amount, UOM) are masked before the untrusted translation and restored byte-exact; a
  # human-facing display label MAY translate (semantic-governed). Any placeholder inventory
  # violation, injected fact, or semantic rejection fails CLOSED to English. Localizing into 'id'
  # here stands in for any non-English configured language — no language/phrase is hardcoded.
  describe 'D7 — configured-language consistency with exact fact preservation' do
    before { allow(Marine::Llm::LanguageDetector).to receive(:new).and_return(detector_for('id')) }

    let(:token_re) { Marine::Catalog::FactPlaceholderMask::TOKEN }
    let(:price_text) { 'The price for IMP-3 is IDR 150000 per pcs.' }
    let(:price_descriptor) { { kind: :price_available, variant_code: 'IMP-3', price_list_rate: '150000', currency: 'IDR', uom: 'pcs' } }

    def localize_price(&)
      stub_masking_translation(&)
      localize(text: price_text, action: :reply, descriptor: price_descriptor)
    end

    it 'accepts a translated family display label when the semantic validator confirms equivalence' do
      caption = 'Here is the product catalog for Impeller.'
      descriptor = { kind: :catalog, family_code: 'IMP', family_name: 'Impeller' }
      stub_masking_translation { |masked| masked.gsub('Here is the product catalog for Impeller.', 'Ini katalog produk untuk Baling-baling.') }
      stub_semantic(true)

      expect(localize(text: caption, action: :send_catalog, descriptor: descriptor)).to eq('Ini katalog produk untuk Baling-baling.')
    end

    it 'rejects a translated display label the semantic validator does not certify (not equivalent)' do
      caption = 'Here is the product catalog for Impeller.'
      descriptor = { kind: :catalog, family_code: 'IMP', family_name: 'Impeller' }
      stub_masking_translation { |masked| masked.gsub('Here is the product catalog for Impeller.', 'Ini katalog produk untuk Propeller.') }
      stub_semantic(false)

      expect(localize(text: caption, action: :send_catalog, descriptor: descriptor)).to eq(caption)
    end

    it 'restores a mutated immutable fact by failing closed (a placeholder replaced by a literal is dropped)' do
      validator = stub_semantic(true)
      # The translator rewrites a fact placeholder to a literal changed currency; that placeholder is now missing.
      expect(localize_price { |masked| masked.sub(token_re, 'USD') }).to eq(price_text)
      expect(validator).not_to have_received(:valid?) # restoration fails closed before the semantic call
    end

    it 'rejects a DROPPED placeholder' do
      stub_semantic(true)
      expect(localize_price { |masked| masked.sub(token_re, '') }).to eq(price_text)
    end

    it 'rejects a DUPLICATED placeholder' do
      stub_semantic(true)
      expect(localize_price { |masked| "#{masked} #{masked[token_re]}" }).to eq(price_text)
    end

    it 'rejects an UNKNOWN placeholder id never produced by the mask' do
      stub_semantic(true)
      unknown = "#{Marine::Catalog::FactPlaceholderMask::OPEN}ZZ#{Marine::Catalog::FactPlaceholderMask::CLOSE}"
      expect(localize_price { |masked| masked + unknown }).to eq(price_text)
    end

    it 'rejects MALFORMED sentinel residue' do
      stub_semantic(true)
      expect(localize_price { |masked| masked + Marine::Catalog::FactPlaceholderMask::OPEN }).to eq(price_text)
    end

    it 'rejects an injected number in the translated prose even with every placeholder intact' do
      validator = stub_semantic(true)
      expect(localize_price { |masked| "#{masked.gsub('The price for', 'Harga untuk')} (5)" }).to eq(price_text)
      expect(validator).not_to have_received(:valid?) # deterministic token inventory rejects before the semantic call
    end

    it 'preserves BOTH facts of a composite price+stock reply in one localized message' do
      composite_text = 'The price for IMP-3 is IDR 150000 per pcs. Good news — that item is currently in stock.'
      descriptor = { kind: :composite,
                     parts: [price_descriptor, { kind: :stock_available }] }
      stub_masking_translation do |masked|
        # Replace the whole stock sentence first, so the later ' is ' substitution only touches price prose.
        masked.gsub('Good news — that item is currently in stock.', 'Kabar baik — barang tersedia.')
              .gsub('The price for', 'Harga untuk').gsub(' is ', ' adalah ')
      end
      stub_semantic(true)

      expect(localize(text: composite_text, action: :reply, descriptor: descriptor))
        .to eq('Harga untuk IMP-3 adalah IDR 150000 per pcs. Kabar baik — barang tersedia.')
    end

    it 'delivers a stock reply in the configured language carrying no quantity' do
      stock_text = 'Good news — that item is currently in stock.'
      stub_masking_translation { |masked| masked.gsub(stock_text, 'Kabar baik — barang tersedia.') }
      stub_semantic(true)

      expect(localize(text: stock_text, action: :reply, descriptor: { kind: :stock_available })).to eq('Kabar baik — barang tersedia.')
    end

    it 'rejects a stock translation that injects a quantity number, back to English' do
      stock_text = 'Good news — that item is currently in stock.'
      stub_masking_translation { |masked| masked.gsub(stock_text, 'Kabar baik — 5 barang tersedia.') }
      stub_semantic(true)

      expect(localize(text: stock_text, action: :reply, descriptor: { kind: :stock_available })).to eq(stock_text)
    end

    it 'never translates or validates an English (source-language) product reply' do
      allow(Marine::Llm::LanguageDetector).to receive(:new).and_return(detector_for('en'))
      expect(Marine::Llm::TranslateResponseService).not_to receive(:new)
      expect(Marine::Charge::FactPreservationValidator).not_to receive(:new)

      expect(localize(text: price_text, action: :reply, descriptor: price_descriptor)).to eq(price_text)
    end

    it 'fails closed to English when the semantic validator raises on a fact-clean translation' do
      validator = instance_double(Marine::Charge::FactPreservationValidator)
      allow(validator).to receive(:valid?).and_raise(StandardError, 'boom')
      allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)

      expect(localize_price { |masked| masked.gsub('The price for', 'Harga untuk') }).to eq(price_text)
    end
  end
end
