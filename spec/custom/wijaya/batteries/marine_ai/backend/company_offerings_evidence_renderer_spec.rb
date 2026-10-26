# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Backend::CompanyOfferingsEvidenceRenderer do
  subject(:renderer) { described_class.new }

  let(:builder) { Marine::Backend::EvidencePacketBuilder.new(clock: -> { Time.utc(2026, 9, 30, 12, 0, 0) }) }

  def packet(language: 'id', fact: nil)
    fact ||= {
      item_groups: %w[Fabric Yarn], returned_count: 2, total_count: 2, complete: true,
      source: 'catalog_item_group_repository', checked_at: '2026-09-30T12:00:00Z'
    }
    builder.build(evidence_input: {
                    scenario: { key: 'scenario_9' }, intents: %w[product_overview], customer_language: language,
                    response_goals: %w[answer_product_overview], validated_slots: {},
                    facts: { company_offerings: fact }, missing_slots: [], variant_candidates: []
                  })
  end

  it 'renders exactly the authoritative item-group categories in Indonesian without item claims' do
    text = renderer.call(packet: packet)

    expect(text).to eq('Kategori produk yang kami tawarkan: Fabric, Yarn.')
    expect(text.scan(/Fabric|Yarn/)).to eq(%w[Fabric Yarn])
    expect(text).not_to match(/stok|stock|harga|price|kode|code/i)
  end

  it 'renders an honest bounded English selection with exact returned/total counts' do
    fact = {
      item_groups: %w[Fabric Yarn], returned_count: 2, total_count: 9, complete: false,
      source: 'catalog_item_group_repository', checked_at: '2026-09-30T12:00:00Z'
    }

    expect(renderer.call(packet: packet(language: 'en', fact: fact)))
      .to eq('Here are 2 of 9 product categories we offer: Fabric, Yarn.')
  end

  it 'is deterministic and does not consult provider, RAG, or repository collaborators' do
    evidence = packet
    first = renderer.call(packet: evidence)

    expect(renderer.call(packet: evidence)).to eq(first)
    expect(evidence).to be_frozen
  end

  it 'fails closed on unsupported language, wrong goal/fact/slot/provenance, or mutable packets' do
    expect(renderer.call(packet: packet(language: 'fr'))).to be_nil

    base = Marshal.load(Marshal.dump(packet))
    expect(renderer.call(packet: base)).to be_nil

    wrong_slot = Marshal.load(Marshal.dump(packet))
    wrong_slot[:validated_slots] = { product: { code: 'FORGED' } }
    deep_freeze(wrong_slot)
    expect(renderer.call(packet: wrong_slot)).to be_nil

    wrong_goal = Marshal.load(Marshal.dump(packet))
    wrong_goal[:response_goals] = %w[answer_product_listing]
    deep_freeze(wrong_goal)
    expect(renderer.call(packet: wrong_goal)).to be_nil

    forged = {
      item_groups: %w[Fabric Yarn], returned_count: 2, total_count: 2, complete: true,
      source: 'rag', checked_at: '2026-09-30T12:00:00Z'
    }
    expect { packet(fact: forged) }.to raise_error(Marine::Backend::EvidencePacketBuilder::InvalidEvidenceInputError)
  end

  it 'fails closed on duplicate/blank groups and inconsistent completeness/count metadata' do
    base = {
      item_groups: %w[Fabric Yarn], returned_count: 2, total_count: 2, complete: true,
      source: 'catalog_item_group_repository', checked_at: '2026-09-30T12:00:00Z'
    }

    [base.merge(item_groups: %w[Fabric Fabric]), base.merge(item_groups: ['Fabric', ' ']),
     base.merge(returned_count: 1), base.merge(total_count: 3),
     base.merge(complete: false, total_count: 2)].each do |fact|
      expect { packet(fact: fact) }.to raise_error(Marine::Backend::EvidencePacketBuilder::InvalidEvidenceInputError)
    end
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end
end
