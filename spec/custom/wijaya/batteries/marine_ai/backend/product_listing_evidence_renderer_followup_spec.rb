# frozen_string_literal: true

require 'rails_helper'

# MVP dynamic follow-up (needs question) on the deterministic Evidence product-listing renderer.
# After the catalog-membership listing line, the renderer appends a localized, factless needs
# question (asking what the fabric is for, to recommend) for BOTH supported languages, on both
# the complete and the bounded page shapes. It stays a question only — no product, price, stock,
# quantity, brand, or completeness claim beyond the existing lead sentence.
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

  it 'appends the Indonesian needs question on a complete id listing' do
    text = renderer.call(packet: listing_packet(products: two_products, returned_count: 2, total_count: 2, complete: true))

    expect(text).to include('AAA', 'BBB')
    expect(text).to end_with(described_class::FOLLOWUP_QUESTION['id'])
  end

  it 'appends the English needs question on a bounded en listing' do
    text = renderer.call(packet: listing_packet(products: two_products, returned_count: 2, total_count: 9,
                                                complete: false, language: 'en'))

    expect(text).to include('2', '9')
    expect(text).to end_with(described_class::FOLLOWUP_QUESTION['en'])
  end

  it 'places the follow-up after the lead sentence and the listed products' do
    text = renderer.call(packet: listing_packet(products: two_products, returned_count: 2, total_count: 2, complete: true))

    lead = 'Berikut produk dalam katalog kami:'
    expect(text).to start_with(lead)
    expect(text.index('AAA')).to be < text.index(described_class::FOLLOWUP_QUESTION['id'])
  end
end
