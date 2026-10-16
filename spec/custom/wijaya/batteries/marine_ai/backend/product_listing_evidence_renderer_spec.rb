# frozen_string_literal: true

require 'rails_helper'

# Step 17 — the deterministic product_listing Evidence renderer. It renders a bounded catalog
# listing reply from a frozen marine_evidence_v2 answer_product_listing packet ALONE, through
# controlled backend-owned localized templates. It reads only the listed products' code + name,
# the returned/total counts, the complete flag, and the packet customer_language; it never reads
# the raw request, calls a provider/RAG/repository, or adds description/stock/price/location/
# delivery/qualitative claims. It fails closed (nil) on a non-listing, malformed, or
# unsupported-language packet.
RSpec.describe Marine::Backend::ProductListingEvidenceRenderer do
  subject(:renderer) { described_class.new }

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end

  def listing_packet(products:, returned_count:, total_count:, complete:, language: 'id')
    packet = {
      evidence_version: 'marine_evidence_v2', generated_at: '2026-09-30T12:00:00Z',
      response_goals: %w[answer_product_listing], scenario: { key: 'scenario_9', intents: %w[product_listing] },
      validated_slots: {},
      facts: { product_listing: { products: products, returned_count: returned_count,
                                  total_count: total_count, complete: complete,
                                  source: 'catalog_listing_repository', checked_at: '2026-09-30T12:00:00Z' }.compact },
      missing_slots: [], variant_candidates: [],
      prohibited_claims: %w[exact_stock_quantity warehouse_location delivery_date unverified_discount price stock],
      response_constraints: { max_paragraphs: 2, role: 'marine_sales_assistant', handoff_self_reference: true },
      customer_language: language
    }
    deep_freeze(packet)
  end

  let(:two_products) { [{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }] }

  describe 'exact Evidence-derived product set and counts' do
    it 'cites exactly the listed codes and names, each literally, and nothing else product-like' do
      text = renderer.call(packet: listing_packet(products: two_products, returned_count: 2, total_count: 2, complete: true))

      expect(text).to include('AAA', 'Alpha', 'BBB', 'Bravo')
      # Exactly the two authorized codes — no third code-like identifier is introduced.
      expect(text.scan(/\b[A-Z]{3}\b/).sort).to eq(%w[AAA BBB])
    end

    it 'renders a code-only product with no parenthetical name when the Evidence carries no name' do
      text = renderer.call(packet: listing_packet(products: [{ code: 'AAA' }], returned_count: 1, total_count: 1, complete: true))

      expect(text).to include('AAA')
      expect(text).not_to include('(')
    end

    it 'retains the exact returned_count and total_count on a bounded (incomplete) page' do
      text = renderer.call(packet: listing_packet(products: two_products, returned_count: 2, total_count: 9, complete: false))

      expect(text).to include('2', '9', 'AAA', 'BBB')
    end
  end

  describe 'honest bounded / incomplete wording' do
    it 'states an incomplete page as bounded and never claims it is the whole catalogue' do
      text = renderer.call(packet: listing_packet(products: two_products, returned_count: 2, total_count: 9, complete: false))

      expect(text).to include('2 dari 9')
      expect(text).not_to match(/seluruh|semua produk kami/i)
    end

    it 'stays bounded ("sebagian") when the incomplete page has no safe total_count' do
      text = renderer.call(packet: listing_packet(products: two_products, returned_count: 2, total_count: nil, complete: false))

      expect(text).to include('sebagian')
      expect(text).to include('AAA', 'BBB')
    end
  end

  describe 'forbidden claims are never emitted' do
    it 'adds no stock, quantity, price, discount, location, warehouse, delivery, or lead-time claim' do
      text = renderer.call(packet: listing_packet(products: two_products, returned_count: 2, total_count: 9, complete: false))

      expect(text).not_to match(/stok|stock|tersedia|harga|price|diskon|discount|gudang|warehouse|kirim|delivery|pengiriman/i)
      # No currency symbol and no number other than the two authorized counts.
      expect(text).not_to match(/\p{Sc}/)
      expect(text.scan(/\d+/).sort).to eq(%w[2 9])
    end
  end

  describe 'localized templates for the contract-supported languages' do
    it 'renders English for an en packet' do
      text = renderer.call(packet: listing_packet(products: two_products, returned_count: 2, total_count: 2, complete: true, language: 'en'))

      expect(text).to match(/catalog/i)
      expect(text).to include('AAA', 'BBB')
    end
  end

  describe 'fail closed (nil) — do not repair' do
    it 'returns nil for an unsupported customer_language' do
      french = listing_packet(products: two_products, returned_count: 2, total_count: 2, complete: true, language: 'fr')
      expect(renderer.call(packet: french)).to be_nil
    end

    it 'returns nil for a product_information goal (this renderer is listing-only)' do
      packet = listing_packet(products: two_products, returned_count: 2, total_count: 2, complete: true)
      info = deep_freeze(packet.merge(response_goals: %w[answer_product_information]))
      expect(renderer.call(packet: info)).to be_nil
    end

    it 'returns nil for a non-listing packet (no product_listing fact)' do
      packet = deep_freeze(
        evidence_version: 'marine_evidence_v2', response_goals: %w[answer_price], facts: { price: { display: 'x' } },
        customer_language: 'id'
      )
      expect(renderer.call(packet: packet)).to be_nil
    end

    it 'returns nil when returned_count disagrees with the actual product page size' do
      expect(renderer.call(packet: listing_packet(products: two_products, returned_count: 5, total_count: 5, complete: true))).to be_nil
    end

    it 'returns nil for an empty or malformed product page' do
      expect(renderer.call(packet: listing_packet(products: [], returned_count: 0, total_count: 0, complete: true))).to be_nil
      expect(renderer.call(packet: { evidence_version: 'nope' }.freeze)).to be_nil
    end

    # Checkpoint A — this v2-only renderer rejects a marine_evidence_v3 packet and never reads its policy.
    it 'returns nil for a marine_evidence_v3 packet (v2-only, never reads presentation_policy)' do
      v2 = listing_packet(products: two_products, returned_count: 2, total_count: 2, complete: true)
      v3 = deep_freeze(v2.to_h.merge(evidence_version: 'marine_evidence_v3',
                                     presentation_policy: { tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code' }))
      expect(renderer.call(packet: v3)).to be_nil
    end
  end
end
