# frozen_string_literal: true

require 'rails_helper'

# price-display-v1 — pure, deterministic DISPLAY formatter for an eligibility-checked
# price_available descriptor. It never queries a DB, calls an LLM, or builds a sentence; it turns
# the raw catalog price facts into a deeply immutable envelope carrying the canonical raw values,
# the approved per-locale display facts, and a raw-to-display provenance map. Exact decimal-string /
# BigDecimal processing, NEVER Float, NEVER rounded. Fails CLOSED (ok? == false, no envelope) on any
# malformed / missing / negative / nonfinite / non-exact amount or unsupported locale/currency/UOM.
RSpec.describe Marine::Catalog::PriceDisplayFormatter do
  subject(:formatter) { described_class.new }

  # Exactly the descriptor keys a :price_available ReplyRenderer descriptor carries.
  def descriptor(price_list_rate:, currency: 'IDR', uom: 'Yard', variant_code: 'BD-20')
    { kind: :price_available, variant_code: variant_code,
      price_list_rate: price_list_rate, currency: currency, uom: uom }
  end

  def envelope(overrides = {})
    result = formatter.format(descriptor: descriptor(**overrides.slice(:price_list_rate, :currency, :uom, :variant_code)),
                              locale: overrides.fetch(:locale, 'id'))
    result.envelope
  end

  describe 'display formatting (id)' do
    it 'groups 12500 with dot thousands, currency Rp, lowercase uom, verbatim code' do
      display = envelope(price_list_rate: '12500', locale: 'id')[:display]
      expect(display).to eq(product: 'BD-20', currency: 'Rp', amount: '12.500', uom: 'yard')
    end

    it 'preserves an exact decimal scale with a comma decimal separator (no rounding)' do
      expect(envelope(price_list_rate: '12500.50', locale: 'id')[:display][:amount]).to eq('12.500,50')
    end

    it 'groups a large value in threes with no ceiling and no rounding' do
      amount = envelope(price_list_rate: '99999999999999999999.123456789', locale: 'id')[:display][:amount]
      expect(amount).to eq('99.999.999.999.999.999.999,123456789')
    end

    it 'renders zero and a sub-unit decimal exactly' do
      expect(envelope(price_list_rate: '0', locale: 'id')[:display][:amount]).to eq('0')
      expect(envelope(price_list_rate: '0.50', locale: 'id')[:display][:amount]).to eq('0,50')
    end
  end

  describe 'display formatting (en)' do
    it 'groups 12500 with comma thousands, currency IDR, lowercase uom' do
      display = envelope(price_list_rate: '12500', locale: 'en')[:display]
      expect(display).to eq(product: 'BD-20', currency: 'IDR', amount: '12,500', uom: 'yard')
    end

    it 'preserves an exact decimal scale with a dot decimal separator' do
      expect(envelope(price_list_rate: '12500.50', locale: 'en')[:display][:amount]).to eq('12,500.50')
    end
  end

  describe 'exact numeric inputs (never Float, never rounded)' do
    it 'accepts an Integer rate' do
      expect(envelope(price_list_rate: 12_500, locale: 'id')[:display][:amount]).to eq('12.500')
    end

    it 'accepts a finite BigDecimal rate in plain (non-scientific) form' do
      expect(envelope(price_list_rate: BigDecimal('12500.75'), locale: 'en')[:display][:amount]).to eq('12,500.75')
    end

    it 'trims redundant leading integer zeros while keeping the fraction byte-exact' do
      expect(envelope(price_list_rate: '012500', locale: 'id')[:display][:amount]).to eq('12.500')
    end

    it 'REJECTS a Float outright (it cannot promise exactness)' do
      expect(formatter.format(descriptor: descriptor(price_list_rate: 12_500.5), locale: 'id').ok?).to be(false)
    end
  end

  describe 'fail-closed rejection (ok? == false, no envelope)' do
    def reason(overrides)
      formatter.format(descriptor: descriptor(**overrides.except(:locale)), locale: overrides.fetch(:locale, 'id')).reason
    end

    it 'rejects an unsupported locale' do
      result = formatter.format(descriptor: descriptor(price_list_rate: '12500'), locale: 'fr')
      expect(result.ok?).to be(false)
      expect(result.reason).to eq(:unsupported_locale)
      expect(result.envelope).to be_nil
    end

    it 'rejects a malformed / non-hash / wrong-shape descriptor' do
      expect(formatter.format(descriptor: nil, locale: 'id').reason).to eq(:malformed_descriptor)
      expect(formatter.format(descriptor: { kind: :price_available }, locale: 'id').reason).to eq(:malformed_descriptor)
      expect(formatter.format(descriptor: { kind: :stock_available, variant_code: 'BD-20' }, locale: 'id').reason).to eq(:malformed_descriptor)
    end

    it 'rejects a missing / blank required field' do
      expect(reason(price_list_rate: '12500', variant_code: '  ')).to eq(:missing_field)
      expect(reason(price_list_rate: '12500', currency: ' ')).to eq(:missing_field)
      expect(reason(price_list_rate: '12500', uom: '')).to eq(:missing_field)
    end

    it 'rejects an invalid / negative / nonfinite / non-exact amount' do
      expect(reason(price_list_rate: 'abc')).to eq(:invalid_amount)
      expect(reason(price_list_rate: nil)).to eq(:invalid_amount)
      expect(reason(price_list_rate: '-5')).to eq(:invalid_amount)
      expect(reason(price_list_rate: BigDecimal('-5'))).to eq(:invalid_amount)
      expect(reason(price_list_rate: BigDecimal('Infinity'))).to eq(:invalid_amount)
      expect(reason(price_list_rate: '12,500')).to eq(:invalid_amount) # embedded grouping is not canonical
    end

    it 'rejects an unsupported currency and an unsupported UOM' do
      expect(reason(price_list_rate: '12500', currency: 'USD')).to eq(:unsupported_currency)
      expect(reason(price_list_rate: '12500', uom: 'kg2')).to eq(:unsupported_uom) # a digit pollutes the fact inventory
    end
  end

  describe 'canonical retention & provenance' do
    it 'retains the raw canonical facts verbatim alongside the display facts' do
      env = envelope(price_list_rate: '12500', locale: 'id')
      expect(env[:canonical]).to eq(variant_code: 'BD-20', currency: 'IDR', price_list_rate: '12500', uom: 'Yard')
    end

    it 'records a raw-to-display provenance for every fact' do
      env = envelope(price_list_rate: '12500', locale: 'id')
      expect(env[:provenance]).to eq(
        product: { raw: 'BD-20', display: 'BD-20' },
        currency: { raw: 'IDR', display: 'Rp' },
        amount: { raw: '12500', display: '12.500' },
        uom: { raw: 'Yard', display: 'yard' }
      )
    end

    it 'stamps the policy version and locale on the envelope' do
      env = envelope(price_list_rate: '12500', locale: 'en')
      expect(env[:policy_version]).to eq('price-display-v1')
      expect(env[:locale]).to eq('en')
      expect(described_class::POLICY_VERSION).to eq('price-display-v1')
    end
  end

  describe 'immutability' do
    let(:env) { envelope(price_list_rate: '12500', locale: 'id') }

    it 'is deeply frozen — the envelope, its nested hashes, and its string values' do
      expect(env).to be_frozen
      expect(env[:display]).to be_frozen
      expect(env[:provenance][:amount]).to be_frozen
      expect(env[:display][:amount]).to be_frozen
    end

    it 'raises rather than allowing a display fact to be mutated' do
      expect { env[:display][:currency] = 'X' }.to raise_error(FrozenError)
      expect { env[:display][:amount] << '0' }.to raise_error(FrozenError)
    end
  end
end
