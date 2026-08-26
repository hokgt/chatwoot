# frozen_string_literal: true

require 'rails_helper'

# D7 — FactPlaceholderMask masks a product reply's IMMUTABLE fact values (codes, currency, UOM,
# price amount, composite-part facts) with opaque placeholders before an untrusted LLM localizes
# the text, then restores them byte-exact — failing CLOSED on any placeholder inventory violation.
# Human-facing DISPLAY LABELS (family/candidate name, attribute names) are deliberately left
# unmasked so they may be translated; the decision is by descriptor field ROLE, not by content or
# language. These examples drive the real mask output (never hardcoding the placeholder format) and
# simulate a translator that rephrases prose while leaving the opaque markers verbatim.
RSpec.describe Marine::Catalog::FactPlaceholderMask do
  # A well-behaved translator leaves the opaque placeholders untouched; only prose changes here.
  def translate(masked, prose = {})
    prose.reduce(masked) { |text, (from, to)| text.gsub(from, to) }
  end

  describe 'immutable fact masking and exact restoration' do
    it 'masks every immutable price field, leaves prose translatable, and restores byte-exact' do
      descriptor = { kind: :price_available, variant_code: 'IMP-3', price_list_rate: '150000', currency: 'IDR', uom: 'pcs' }
      mask = described_class.new(descriptor: descriptor)
      source = 'The price for IMP-3 is IDR 150000 per pcs.'

      masked = mask.mask(source)

      # The immutable values are gone from the masked text the translator will see...
      expect(masked).not_to include('IMP-3', 'IDR', '150000', 'pcs')
      # ...and a faithful prose-only translation restores them exactly.
      translated = translate(masked, 'The price for' => 'Harga untuk', ' is ' => ' adalah ')
      expect(mask.restore(translated)).to eq('Harga untuk IMP-3 adalah IDR 150000 per pcs.')
    end

    it 'masks the variant code in a variant_info reply' do
      mask = described_class.new(descriptor: { kind: :variant_info, family_code: 'IMP', variant_code: 'AB12' })
      masked = mask.mask('Here are the details for AB12. Would you like the price or availability?')

      expect(masked).not_to include('AB12')
      translated = translate(masked, 'Here are the details for' => 'Berikut detail untuk',
                                     'Would you like the price or availability?' => 'Mau harga atau ketersediaan?')
      expect(mask.restore(translated)).to eq('Berikut detail untuk AB12. Mau harga atau ketersediaan?')
    end

    it 'masks the union of a composite reply\'s immutable part facts and restores them all' do
      descriptor = {
        kind: :composite,
        parts: [
          { kind: :price_available, variant_code: 'IMP-3', price_list_rate: '150000', currency: 'IDR', uom: 'pcs' },
          { kind: :stock_available }
        ]
      }
      mask = described_class.new(descriptor: descriptor)
      source = 'The price for IMP-3 is IDR 150000 per pcs. Good news — that item is currently in stock.'

      masked = mask.mask(source)
      expect(masked).not_to include('IMP-3', 'IDR', '150000', 'pcs')
      # Replace the whole stock sentence first, so the later ' is ' substitution only touches the price prose.
      translated = translate(masked, 'Good news — that item is currently in stock.' => 'Kabar baik — barang tersedia.',
                                     'The price for' => 'Harga untuk', ' is ' => ' adalah ')
      expect(mask.restore(translated)).to eq('Harga untuk IMP-3 adalah IDR 150000 per pcs. Kabar baik — barang tersedia.')
    end

    it 'preserves a short immutable value that is a token of a longer one (longest-first masking)' do
      # Both "IMP" (family code, standalone) and "IMP-3" (variant code) appear; masking longest-first
      # keeps each intact through restoration.
      descriptor = { kind: :variant_info, family_code: 'IMP', variant_code: 'IMP-3' }
      mask = described_class.new(descriptor: descriptor)
      source = 'IMP family: here are the details for IMP-3.'

      masked = mask.mask(source)
      restored = mask.restore(translate(masked, 'family: here are the details for' => 'keluarga: detail untuk'))
      expect(restored).to eq('IMP keluarga: detail untuk IMP-3.')
    end
  end

  describe 'display labels are NOT masked (translatable wording)' do
    it 'leaves a catalog caption family NAME unmasked so it can translate' do
      mask = described_class.new(descriptor: { kind: :catalog, family_code: 'IMP', family_name: 'Impeller' })
      source = 'Here is the product catalog for Impeller.'

      # The rendered value is the NAME (a display label); the code "IMP" is not in the text, so
      # nothing is masked and the whole caption is free to translate.
      expect(mask.mask(source)).to eq(source)
      translated = translate(mask.mask(source), source => 'Ini katalog produk untuk Baling-baling.')
      expect(mask.restore(translated)).to eq('Ini katalog produk untuk Baling-baling.')
    end

    it 'masks the family CODE when it stands in for a blank name (an identifier, not a label)' do
      mask = described_class.new(descriptor: { kind: :parent_info, family_code: 'IMP', family_name: nil })
      source = "You're asking about IMP. Which specific variant would you like to know about?"

      masked = mask.mask(source)
      expect(masked).not_to include('IMP')
      restored = mask.restore(translate(masked, "You're asking about" => 'Anda menanyakan',
                                                'Which specific variant would you like to know about?' => 'Varian mana yang Anda inginkan?'))
      expect(restored).to eq('Anda menanyakan IMP. Varian mana yang Anda inginkan?')
    end

    it 'leaves clarify_variant attribute names entirely unmasked' do
      mask = described_class.new(descriptor: { kind: :clarify_variant, attribute_names: %w[size material] })
      source = 'Could you specify the size, material you need?'

      expect(mask.mask(source)).to eq(source)
    end

    it 'leaves a stock reply unmasked (no immutable fact, availability only)' do
      mask = described_class.new(descriptor: { kind: :stock_available })
      expect(mask.mask('Good news — that item is currently in stock.')).to eq('Good news — that item is currently in stock.')
    end
  end

  describe 'restore fails closed on any placeholder inventory violation' do
    let(:descriptor) { { kind: :price_available, variant_code: 'IMP-3', price_list_rate: '150000', currency: 'IDR', uom: 'pcs' } }
    let(:mask) { described_class.new(descriptor: descriptor) }
    let(:source) { 'The price for IMP-3 is IDR 150000 per pcs.' }

    def a_placeholder(masked)
      masked[described_class::TOKEN]
    end

    it 'rejects a DROPPED placeholder (a fact silently removed in translation)' do
      masked = mask.mask(source)
      dropped = masked.sub(a_placeholder(masked), '')
      expect(mask.restore(dropped)).to be_nil
    end

    it 'rejects a DUPLICATED placeholder' do
      masked = mask.mask(source)
      token = a_placeholder(masked)
      expect(mask.restore("#{masked} #{token}")).to be_nil
    end

    it 'rejects an UNKNOWN placeholder id never produced by mask' do
      masked = mask.mask(source)
      unknown = "#{described_class::OPEN}ZZ#{described_class::CLOSE}"
      expect(mask.restore(masked + unknown)).to be_nil
    end

    it 'rejects MALFORMED sentinel residue (a stray, unmatched sentinel char)' do
      masked = mask.mask(source)
      expect(mask.restore(masked + described_class::OPEN)).to be_nil
    end

    it 'returns nil when the SOURCE already carries a sentinel char (cannot mask safely)' do
      expect(mask.mask("#{source}#{described_class::OPEN}")).to be_nil
    end

    it 'restores the untouched masked text when the translator preserves every placeholder' do
      masked = mask.mask(source)
      expect(mask.restore(masked)).to eq(source)
    end
  end

  describe 'genericity — no hardcoded product or language data' do
    it 'masks and restores an arbitrary non-English family code and price' do
      descriptor = { kind: :price_available, variant_code: 'ZZ9-Ä', price_list_rate: '42', currency: 'EUR', uom: 'stück' }
      mask = described_class.new(descriptor: descriptor)
      source = 'The price for ZZ9-Ä is EUR 42 per stück.'

      masked = mask.mask(source)
      expect(masked).not_to include('ZZ9', 'EUR', '42', 'stück')
      expect(mask.restore(masked)).to eq(source)
    end
  end
end
