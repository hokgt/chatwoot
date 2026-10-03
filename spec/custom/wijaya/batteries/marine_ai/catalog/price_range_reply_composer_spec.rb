# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::PriceRangeReplyComposer, type: :model do
  subject(:composer) { described_class.new(account: nil) }

  # A raw :price_range descriptor exactly as Marine::Catalog::ReplyRenderer#price_range emits it:
  # repository-derived canonical decimal strings, raw currency/UOM, and the family labels.
  def descriptor(min: '12500', max: '45000', currency: 'IDR', uom: 'yard')
    { kind: :price_range, family_code: 'BD', family_name: 'Baby Doll',
      price_min: min, price_max: max, currency: currency, uom: uom }
  end

  describe '#display_facts (reused PriceDisplayFormatter policy for both endpoints)' do
    it 'formats an Indonesian range with the Rp symbol and dot thousands grouping' do
      expect(composer.display_facts(descriptor, 'id'))
        .to eq(currency: 'Rp', uom: 'yard', min: '12.500', max: '45.000')
    end

    it 'formats an English range with the IDR code and comma thousands grouping' do
      expect(composer.display_facts(descriptor, 'en'))
        .to eq(currency: 'IDR', uom: 'yard', min: '12,500', max: '45,000')
    end

    it 'collapses equal endpoints to a single amount (both endpoints format identically)' do
      facts = composer.display_facts(descriptor(min: '12500', max: '12500'), 'id')
      expect(facts[:min]).to eq('12.500')
      expect(facts[:min]).to eq(facts[:max])
    end

    it 'keeps canonical decimals repository-derived — the formatter never rounds a scaled amount' do
      expect(composer.display_facts(descriptor(min: '12500.50', max: '45000'), 'id'))
        .to eq(currency: 'Rp', uom: 'yard', min: '12.500,50', max: '45.000')
    end

    it 'fails closed to nil when a required range fact is blank' do
      expect(composer.display_facts(descriptor(currency: ''), 'id')).to be_nil
    end

    it 'fails closed to nil for an unsupported display locale' do
      expect(composer.display_facts(descriptor, 'fr')).to be_nil
    end
  end

  describe '#compose' do
    it 'delivers an English caption that grounds the display range and points at the attached catalog' do
      decision = composer.compose(descriptor: descriptor, reply_language: 'en', customer_request: 'price?',
                                  catalog_attached: true)

      expect(decision).to be_deliver
      expect(decision.text).to eq(
        'Prices for Baby Doll range from IDR 12,500 to IDR 45,000 per yard. ' \
        "Please reply with the exact variant code shown in the catalog and I'll confirm the exact price for you."
      )
    end

    it 'never claims a catalog is shown when no attachment is delivered' do
      decision = composer.compose(descriptor: descriptor, reply_language: 'en', customer_request: 'price?',
                                  catalog_attached: false)

      expect(decision).to be_deliver
      expect(decision.text).to eq(
        'Prices for Baby Doll range from IDR 12,500 to IDR 45,000 per yard. ' \
        "Please reply with the exact variant code and I'll confirm the exact price for you."
      )
      expect(decision.text).not_to include('shown in the catalog')
    end

    it 'renders a single amount for equal endpoints' do
      decision = composer.compose(descriptor: descriptor(min: '12500', max: '12500'), reply_language: 'en',
                                  customer_request: 'price?', catalog_attached: true)

      expect(decision.text).to start_with('The price for Baby Doll is IDR 12,500 per yard.')
    end

    it 'falls back (no raw or wrong-language range) when the resolved reply language is unsupported' do
      # A valid but unsupported provider language is authoritative and never falls through to a
      # supported detected one — it fails closed to the safe clarification, exactly like exact pricing.
      decision = composer.compose(descriptor: descriptor, reply_language: 'fr', customer_request: 'prix?',
                                  catalog_attached: true)

      expect(decision).to be_fallback
      expect(decision.text).to be_nil
    end

    it 'falls back when no reply-language signal resolves at all' do
      allow(Marine::Llm::LanguageDetector).to receive(:new).and_return(
        instance_double(Marine::Llm::LanguageDetector, detect: { language: 'unknown', reliable: false, confidence: 0.0 })
      )

      decision = composer.compose(descriptor: descriptor, reply_language: nil, customer_request: 'x',
                                  catalog_attached: true)

      expect(decision).to be_fallback
    end

    it 'falls back for a malformed range descriptor' do
      expect(composer.compose(descriptor: { kind: :price_available }, reply_language: 'en',
                              customer_request: 'x', catalog_attached: true)).to be_fallback
    end

    it 'resolves to the assistant configured language when the provider language is absent' do
      decision = composer.compose(descriptor: descriptor, reply_language: nil, configured_language: 'en',
                                  customer_request: 'price?', catalog_attached: true)

      expect(decision).to be_deliver
      expect(decision.text).to include('IDR 12,500')
    end
  end
end
