# frozen_string_literal: true

require 'rails_helper'

# Shared deterministic product-flow language resolver. The local detector is stubbed so the
# suite is deterministic and independent of CLD3's presence in the test image: each example
# declares exactly which texts detect reliably and to what language. All entity/code values are
# SYNTHETIC (no real catalog code) and no behavior is keyed to any particular code shape.
RSpec.describe Marine::Catalog::ConversationLanguageResolver do
  # Map of text => detector result; anything unlisted detects as unknown/unreliable (a bare
  # product code / slot answer).
  let(:detections) { {} }

  before do
    allow(Marine::Llm::LanguageDetector).to receive(:new) do |text|
      result = detections.fetch(text.to_s, language: 'unknown', reliable: false, confidence: 0.0)
      instance_double(Marine::Llm::LanguageDetector, detect: result)
    end
  end

  def reliable(language)
    { language: language, reliable: true, confidence: 0.99 }
  end

  def user(content)
    { role: 'user', content: content }
  end

  def assistant(content)
    { role: 'assistant', content: content }
  end

  def resolve(**)
    described_class.resolve(**)
  end

  describe 'entity/code-only continuation (the reported provider misclassification)' do
    it 'ignores an English provider guess for a bare code and inherits the Indonesian prior history' do
      detections['halo berapa harganya semuanya'] = reliable('id')

      result = resolve(text: 'ZX-90', provider_language: 'en',
                       context: [user('halo berapa harganya semuanya')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end

    it 'treats a MULTI-SEGMENT fresh exact entity candidate (not a slot_value hint) as non-linguistic' do
      # "QLR-2200" carries two 3+ char runs, so a naive token count would call it meaningful; the
      # bounded extracted candidate marks it as the entity it is, regardless of code shape.
      detections['halo berapa harganya semuanya'] = reliable('id')

      result = resolve(text: 'QLR-2200', provider_language: 'en', entity_candidates: ['QLR-2200'],
                       context: [user('halo berapa harganya semuanya')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end

    it 'does not trust even a RELIABLE local detection of a bare entity (no code sets the language)' do
      # The code itself detects reliably as English, but an entity-only turn trusts neither the
      # provider nor CLD3 for that entity — it inherits the prior customer language instead.
      detections['NORDA-5000'] = reliable('en')
      detections['halo berapa harganya semuanya'] = reliable('id')

      result = resolve(text: 'NORDA-5000', provider_language: nil, entity_candidates: ['NORDA-5000'],
                       context: [user('halo berapa harganya semuanya')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end

    it 'inherits English when the prior customer history is English (entity provider guess ignored)' do
      detections['what is the price please'] = reliable('en')

      result = resolve(text: 'ZX-90', provider_language: 'id',
                       context: [user('what is the price please')])

      expect(result.language).to eq('en')
    end
  end

  describe 'meaningful current turn is authoritative (intentional switching)' do
    it 'keeps the current-turn provider language for a meaningful Indonesian message' do
      result = resolve(text: 'Berapa harga produk ini?', provider_language: 'id')

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:current_turn)
    end

    it 'lets a candidate PLUS meaningful English wording switch from Indonesian history' do
      detections['halo apa kabar semuanya'] = reliable('id')

      result = resolve(text: 'QLR-2200 what is the price please', provider_language: 'en',
                       entity_candidates: ['QLR-2200'], context: [user('halo apa kabar semuanya')])

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:current_turn)
    end

    it 'keeps authority for a full meaningful sentence even when it also supplies a slot value' do
      # A slot answer that is itself a meaningful sentence is NOT erased just because it answered a
      # slot: entity/slot-only content is the condition, not a scope label. The attribute candidate is
      # stripped, but the surrounding real wording keeps the turn authoritative.
      detections['halo berapa harganya semuanya'] = reliable('id')

      result = resolve(text: 'yes please give me the blue one', provider_language: 'en',
                       entity_candidates: ['blue'], context: [user('halo berapa harganya semuanya')])

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:current_turn)
    end

    it 'falls back to a reliable local detection of the current turn when the provider is silent' do
      detections['Boleh minta harganya semuanya?'] = reliable('id')

      result = resolve(text: 'Boleh minta harganya semuanya?', provider_language: nil)

      expect(result.language).to eq('id')
    end
  end

  describe 'nearest reliable customer turn wins in mixed bounded history' do
    it 'prefers the newest reliable customer turn' do
      detections['what is the price please'] = reliable('en')
      detections['halo berapa harganya semuanya'] = reliable('id')

      # Oldest -> newest; the newest customer turn is Indonesian.
      context = [user('what is the price please'), assistant('The price is ...'), user('halo berapa harganya semuanya')]

      expect(resolve(text: 'ZX-90', provider_language: 'en', context: context).language).to eq('id')
    end

    it 'flips with the ordering when the newest customer turn is English' do
      detections['what is the price please'] = reliable('en')
      detections['halo berapa harganya semuanya'] = reliable('id')

      context = [user('halo berapa harganya semuanya'), assistant('...'), user('what is the price please')]

      expect(resolve(text: 'ZX-90', provider_language: 'en', context: context).language).to eq('en')
    end
  end

  describe 'assistant/history turns never determine customer language' do
    it 'ignores an assistant turn even when it is the only reliably detectable language' do
      detections['Guten Tag, wie kann ich Ihnen helfen?'] = reliable('de')

      result = resolve(text: 'ZX-90', provider_language: 'en',
                       context: [assistant('Guten Tag, wie kann ich Ihnen helfen?')])

      expect(result.language).to be_nil
      expect(result.reason).to eq(:unresolved)
    end

    it 'prefers the configured language over an assistant-only detectable language' do
      detections['Guten Tag zusammen heute'] = reliable('de')

      result = resolve(text: 'ZX-90', provider_language: 'en', configured_language: 'en',
                       context: [assistant('Guten Tag zusammen heute')])

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:configured)
    end

    it 'ignores role-less context entries (unknowable role, fail closed)' do
      detections['halo berapa harganya semuanya'] = reliable('id')

      result = resolve(text: 'ZX-90', provider_language: 'en',
                       context: ['halo berapa harganya semuanya', { content: 'halo berapa harganya semuanya' }])

      expect(result.language).to be_nil
    end
  end

  describe 'configured-language fallback and fail-closed behavior' do
    it 'falls back to the configured assistant language when no customer language is reliable' do
      result = resolve(text: 'ZX-90', provider_language: 'en', configured_language: 'id')

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:configured)
    end

    it 'returns nil (fail closed) when nothing resolves — never forcing English or Indonesian' do
      result = resolve(text: 'ZX-90', provider_language: 'en')

      expect(result.language).to be_nil
      expect(result.reason).to eq(:unresolved)
    end

    it 'preserves a valid-but-unsupported current language instead of forcing a supported one' do
      result = resolve(text: 'Quel est le prix de ce produit?', provider_language: 'fr')

      expect(result.language).to eq('fr')
    end
  end

  describe 'alias canonicalization' do
    it 'canonicalizes the deprecated Indonesian alias in -> id from the provider' do
      result = resolve(text: 'Berapa harga produk ini?', provider_language: 'in')

      expect(result.language).to eq('id')
    end

    it 'canonicalizes a deprecated alias from a prior customer turn detection' do
      detections['halo berapa harganya semuanya'] = reliable('in')

      result = resolve(text: 'ZX-90', provider_language: 'en', context: [user('halo berapa harganya semuanya')])

      expect(result.language).to eq('id')
    end
  end

  describe 'bounded context only (no DB / no provider call)' do
    it 'consults only the supplied context and never constructs a translation/provider client' do
      # The only collaborator it may touch is the local detector; assert no other Marine LLM
      # service is instantiated (no extra provider call).
      expect(Marine::Llm::BaseService).not_to receive(:new)

      resolve(text: 'ZX-90', provider_language: 'en', context: [], configured_language: 'en')
    end
  end
end
