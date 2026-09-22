# frozen_string_literal: true

require 'rails_helper'

# Local, model-free numeric-price backstop: flags an explicit monetary product-price claim (a
# configured currency token adjacent to a number) while leaving ordinary non-price numbers —
# dates, product/variant codes, telephone numbers, addresses, quantities — untouched.
RSpec.describe Marine::Charge::PriceClaimInspector do
  subject(:inspector) { described_class.new }

  describe '#monetary_price_claim?' do
    it 'derives its currency tokens from the catalog display policy (no hardcoded list)' do
      expected = (Marine::Catalog::PriceDisplayFormatter::CURRENCY_DISPLAY.keys +
                  Marine::Catalog::PriceDisplayFormatter::CURRENCY_DISPLAY.values.flat_map(&:values))
                 .map(&:downcase).uniq
      expect(described_class.currency_tokens).to match_array(expected)
    end

    context 'with an explicit monetary product-price claim' do
      it 'flags the incident-shaped id claim (currency then amount)' do
        expect(inspector.monetary_price_claim?(reply: 'Harga kain itu adalah Rp 28.500 per yard.')).to be(true)
      end

      it 'flags an en claim with grouped IDR' do
        expect(inspector.monetary_price_claim?(reply: 'The price is IDR 9,750 per yard.')).to be(true)
      end

      it 'flags a currency token with no space before the amount' do
        expect(inspector.monetary_price_claim?(reply: 'Rp28.500/yard')).to be(true)
      end

      it 'flags an amount stated before the currency token' do
        expect(inspector.monetary_price_claim?(reply: 'It costs 28.500 Rp.')).to be(true)
      end

      it 'flags a colon-separated claim' do
        expect(inspector.monetary_price_claim?(reply: 'Price IDR: 12500')).to be(true)
      end
    end

    context 'with ordinary non-price numbers (no false positives)' do
      it 'does not flag a date' do
        expect(inspector.monetary_price_claim?(reply: 'We reopen on 22 September 2026.')).to be(false)
      end

      it 'does not flag a product / variant code' do
        expect(inspector.monetary_price_claim?(reply: 'The variant code is PL-6 and family 1HY-2.')).to be(false)
      end

      it 'does not flag a telephone number' do
        expect(inspector.monetary_price_claim?(reply: 'Call us at +62 812 3456 7890 anytime.')).to be(false)
      end

      it 'does not flag a street address' do
        expect(inspector.monetary_price_claim?(reply: 'Our office is at Jl. Sudirman No. 28, Bandung.')).to be(false)
      end

      it 'does not flag a plain quantity / MOQ' do
        expect(inspector.monetary_price_claim?(reply: 'The minimum order is 50 yard per color.')).to be(false)
      end

      it 'does not flag ordinary words that merely contain a currency substring' do
        expect(inspector.monetary_price_claim?(reply: 'That is a sharp 100% cotton corp order of 5 rolls.')).to be(false)
      end

      it 'does not flag a currency mention with no adjacent number' do
        expect(inspector.monetary_price_claim?(reply: 'We accept payment in IDR by bank transfer.')).to be(false)
      end

      it 'is false for a blank reply' do
        expect(inspector.monetary_price_claim?(reply: '')).to be(false)
        expect(inspector.monetary_price_claim?(reply: nil)).to be(false)
      end
    end
  end
end
