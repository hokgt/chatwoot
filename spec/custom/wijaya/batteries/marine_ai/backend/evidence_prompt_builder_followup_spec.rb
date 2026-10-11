# frozen_string_literal: true

require 'rails_helper'

# MVP dynamic follow-up — the Model 2 prompt contract for a product listing must instruct the
# model to close its reply with a factless needs question (what the products are needed for, so
# assistant can recommend), in addition to the existing exact-set / completeness contract.
RSpec.describe Marine::Backend::EvidencePromptBuilder do
  let(:builder) { described_class.new }
  let(:products) { [{ code: 'AAA', name: 'Alpha' }] }

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end

  def listing_packet
    deep_freeze(
      evidence_version: 'marine_evidence_v2', generated_at: '2026-09-30T12:00:00Z',
      response_goals: %w[answer_product_listing], scenario: { key: 'scenario_9', intents: %w[product_listing] },
      validated_slots: {},
      facts: { product_listing: { products: products, returned_count: 1, total_count: 5, complete: false,
                                  source: 'catalog_listing_repository', checked_at: '2026-09-30T12:00:00Z' } },
      missing_slots: [], variant_candidates: [],
      prohibited_claims: %w[exact_stock_quantity warehouse_location delivery_date unverified_discount price stock],
      response_constraints: { max_paragraphs: 2, role: 'marine_sales_assistant', handoff_self_reference: true },
      customer_language: 'id'
    )
  end

  it 'instructs Model 2 to end a listing reply with a needs question for recommendations' do
    prompt = builder.build(packet: listing_packet, customer_request: 'kain apa saja yang ada?')

    expect(prompt[:system]).to include(described_class::LISTING_NEEDS_QUESTION_INSTRUCTION)
  end

  it 'keeps the instruction factless — it authorizes no product, price, or stock claim' do
    instruction = described_class::LISTING_NEEDS_QUESTION_INSTRUCTION

    expect(instruction).to match(/what they need the products for|kebutuhan/i)
    %w[http www].each do |forbidden|
      expect(instruction.downcase).not_to include(forbidden)
    end
    # It explicitly FORBIDS adding claims beyond the packet.
    expect(instruction).to include('add no product, price, or stock claim')
  end
end
