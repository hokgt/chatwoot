# frozen_string_literal: true

require 'rails_helper'

# Step 18 — the deterministic exact-price Evidence renderer. It renders an exact-price reply from a
# frozen marine_evidence_v2 answer_price packet ALONE, through the existing approved price-display-v1
# id/en template. Its only business-fact input is the authoritative, formatter-validated display block
# (product, currency, amount, uom) plus the packet customer_language; it never reads the Model 2
# candidate, the raw request/history, a provider/RAG/repository/DB, and never adds stock/quantity,
# location/warehouse, delivery/lead-time, discount/promotion, comparison/history, or any qualitative
# claim. It fails closed (nil) on a non-price, multi-goal, malformed, or unsupported-language packet.
RSpec.describe Marine::Backend::ExactPriceEvidenceRenderer do
  subject(:renderer) { described_class.new }

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end

  # The full real exact-price fact (mirrors the EvidencePacketBuilder contract). Overridable per key so
  # the fail-closed specs can drop/mangle any required area (canonical / display / policy / source /
  # checked_at) independently.
  def price_fact(canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' },
                 display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' },
                 policy_version: 'price-display-v1', source: 'catalog_price_repository',
                 checked_at: '2026-09-30T12:00:00Z')
    { canonical: canonical, display: display, policy_version: policy_version, source: source, checked_at: checked_at }
  end

  # A deeply-frozen marine_evidence_v2 answer_price packet carrying exactly the [:price] fact with the
  # authoritative, formatter-validated display block. `freeze: false` yields a mutable pseudo-packet.
  def price_packet(display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' }, # rubocop:disable Metrics/ParameterLists -- a flexible packet fixture whose every contract area is independently overridable
                   language: 'id', goals: %w[answer_price], facts: :default,
                   scenario: { key: 'scenario_5', intents: %w[price] },
                   validated_slots: { variant: { code: 'BD-4', resolution_status: 'resolved', source: 'marine_catalog', attributes: {} } },
                   freeze: true)
    facts = { price: price_fact(display: display) } if facts == :default
    packet = {
      evidence_version: 'marine_evidence_v2', generated_at: '2026-09-30T12:00:00Z',
      response_goals: goals, scenario: scenario, validated_slots: validated_slots,
      facts: facts, missing_slots: [], variant_candidates: [],
      prohibited_claims: %w[exact_stock_quantity warehouse_location delivery_date unverified_discount stock],
      response_constraints: { max_paragraphs: 2, role: 'marine_sales_assistant', handoff_self_reference: true },
      customer_language: language
    }
    freeze ? deep_freeze(packet) : packet
  end

  describe 'authoritative exact-price display from the Evidence alone' do
    it 'renders the approved id template with the exact display identity / price / currency / UOM' do
      text = renderer.call(packet: price_packet)

      expect(text).to eq('Harga BD-4 adalah Rp 12.500 per yard.')
    end

    it 'renders the approved en template for an en packet with the en display facts' do
      text = renderer.call(packet: price_packet(display: { product: 'BD-4', currency: 'IDR', amount: '12,500', uom: 'yard' }, language: 'en'))

      expect(text).to eq('The price for BD-4 is IDR 12,500 per yard.')
    end

    it 'adds NO stock, quantity, location, delivery, discount, promotion, comparison, or qualitative claim' do
      text = renderer.call(packet: price_packet)

      expect(text).not_to match(/stok|stock|tersedia|qty|jumlah|gudang|warehouse|lokasi|kirim|delivery|pengiriman|lead.?time/i)
      expect(text).not_to match(/diskon|discount|promo|promotion|hemat|cheaper|murah|termurah|dibanding|compared|sebelumnya|biasanya/i)
      # Exactly the one authorized grouped-price amount and no other price-shaped number (the digit in
      # the product code BD-4 is authoritative identity, not a price).
      expect(text.scan(/\d{1,3}(?:[.,]\d{3})+/)).to eq(%w[12.500])
      expect(text).not_to match(/\p{Sc}/)
    end
  end

  describe 'purity and safe repeated calls' do
    it 'is deterministic across repeated calls and never mutates the input packet' do
      packet = price_packet
      first = renderer.call(packet: packet)
      second = renderer.call(packet: packet)

      expect(first).to eq(second)
      expect(packet).to be_frozen
      expect(packet[:facts][:price][:display]).to eq(product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard')
    end

    it 'renders from a real EvidencePacketBuilder packet with no repository/DB/RAG/LLM collaborator' do
      packet = Marine::Backend::EvidencePacketBuilder.new(clock: -> { Time.utc(2026, 9, 30, 12, 0, 0) }).build(
        evidence_input: {
          scenario: { key: 'scenario_5' }, intents: %w[price], customer_language: 'id', response_goals: %w[answer_price],
          validated_slots: { variant: { code: 'BD-4', resolution_status: 'resolved', source: 'marine_catalog', attributes: {} } },
          facts: { price: { canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' },
                            display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' },
                            policy_version: 'price-display-v1', source: 'catalog_price_repository', checked_at: '2026-09-30T12:00:00Z' } },
          missing_slots: [], variant_candidates: []
        }
      )

      expect(renderer.call(packet: packet)).to eq('Harga BD-4 adalah Rp 12.500 per yard.')
    end
  end

  describe 'fail closed (nil) — do not repair, never raise' do
    it 'returns nil for an unsupported customer_language' do
      expect(renderer.call(packet: price_packet(language: 'fr'))).to be_nil
    end

    it 'returns nil for a price_range goal (this renderer is exact-price only, never price_range)' do
      range_facts = { price_range: { display: { currency: 'Rp', min: '10.000', max: '12.500', uom: 'yard' } } }
      range = price_packet(goals: %w[answer_price_range], facts: range_facts)
      expect(renderer.call(packet: range)).to be_nil
    end

    it 'returns nil for a multi-goal packet carrying answer_price plus another goal' do
      expect(renderer.call(packet: price_packet(goals: %w[answer_price answer_stock]))).to be_nil
    end

    it 'returns nil for a non-price packet (no price fact)' do
      listing = deep_freeze(evidence_version: 'marine_evidence_v2', response_goals: %w[answer_product_listing],
                            facts: { product_listing: { products: [{ code: 'AAA' }] } }, customer_language: 'id')
      expect(renderer.call(packet: listing)).to be_nil
    end

    it 'returns nil when the display block has a missing / extra / blank / control-bearing field' do
      [{ product: 'BD-4', currency: 'Rp', amount: '12.500' },
       { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard', extra: 'x' },
       { product: 'BD-4', currency: 'Rp', amount: '   ', uom: 'yard' },
       { product: "BD-4\a", currency: 'Rp', amount: '12.500', uom: 'yard' }].each do |display|
        expect(renderer.call(packet: price_packet(display: display))).to be_nil
      end
    end

    it 'returns nil for a malformed / wrong-version packet' do
      expect(renderer.call(packet: { evidence_version: 'nope' }.freeze)).to be_nil
      expect(renderer.call(packet: nil)).to be_nil
      expect(renderer.call(packet: 'x')).to be_nil
    end
  end

  # The renderer is a standalone fail-closed safety component: a partial display-only pseudo-packet — or
  # one missing/malforming any required exact-price contract area (canonical identity/price, provenance
  # source, policy_version, checked_at, variant identity, price-only scenario) — must NEVER render.
  describe 'rejects a partial / malformed exact-price Evidence contract (full contract required)' do
    it 'returns nil for a display-only pseudo-packet (no canonical / policy / source / checked_at)' do
      display_only = { price: { display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' } } }
      expect(renderer.call(packet: price_packet(facts: display_only))).to be_nil
    end

    it 'returns nil when the canonical block is missing, has an extra key, or carries a blank/control value' do
      [price_fact.except(:canonical),
       price_fact(canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard', extra: 'x' }),
       price_fact(canonical: { variant_code: 'BD-4', currency: '  ', price_list_rate: '12500', uom: 'Yard' }),
       price_fact(canonical: { variant_code: "BD-4\a", currency: 'IDR', price_list_rate: '12500', uom: 'Yard' }),
       price_fact(canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: 'free', uom: 'Yard' })].each do |fact|
        expect(renderer.call(packet: price_packet(facts: { price: fact }))).to be_nil
      end
    end

    it 'returns nil when the canonical variant_code does not match the validated variant identity' do
      mismatch = price_fact(canonical: { variant_code: 'ZZ-9', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' })
      expect(renderer.call(packet: price_packet(facts: { price: mismatch }))).to be_nil
    end

    it 'returns nil when the rendered display.product diverges from the authoritative canonical variant_code' do
      # A fully valid, deeply-frozen packet whose canonical identity (and the validated slot) is BD-4 but
      # whose display.product names a divergent-but-safe forged token: the reply would NAME a fabricated
      # identity at the real product's price, so the renderer must fail closed instead.
      forged = price_fact(display: { product: 'ZZ-FORGED-9', currency: 'Rp', amount: '12.500', uom: 'yard' })
      expect(renderer.call(packet: price_packet(facts: { price: forged }))).to be_nil
    end

    it 'returns nil when the validated variant slot is absent or not marine_catalog-sourced' do
      expect(renderer.call(packet: price_packet(validated_slots: {}))).to be_nil
      expect(renderer.call(packet: price_packet(validated_slots: { variant: { code: 'BD-4', source: 'rag_cache', attributes: {} } }))).to be_nil
    end

    it 'returns nil for a missing / wrong policy_version' do
      expect(renderer.call(packet: price_packet(facts: { price: price_fact(policy_version: 'price-display-v2') }))).to be_nil
      expect(renderer.call(packet: price_packet(facts: { price: price_fact.except(:policy_version) }))).to be_nil
    end

    it 'returns nil for a missing / wrong provenance source' do
      expect(renderer.call(packet: price_packet(facts: { price: price_fact(source: 'rag_cache') }))).to be_nil
      expect(renderer.call(packet: price_packet(facts: { price: price_fact.except(:source) }))).to be_nil
    end

    it 'returns nil for a missing / malformed checked_at timestamp' do
      expect(renderer.call(packet: price_packet(facts: { price: price_fact(checked_at: '30-09-2026') }))).to be_nil
      expect(renderer.call(packet: price_packet(facts: { price: price_fact(checked_at: Time.utc(2026, 9, 30)) }))).to be_nil
      expect(renderer.call(packet: price_packet(facts: { price: price_fact.except(:checked_at) }))).to be_nil
    end

    it 'returns nil for a non-price scenario provenance (intents not exactly price)' do
      expect(renderer.call(packet: price_packet(scenario: { key: 'scenario_5', intents: %w[stock] }))).to be_nil
      expect(renderer.call(packet: price_packet(scenario: { key: 'scenario_5', intents: %w[price stock] }))).to be_nil
    end

    it 'returns nil for a mutable (not deeply frozen) pseudo-packet when called directly' do
      expect(renderer.call(packet: price_packet(freeze: false))).to be_nil
    end

    # Checkpoint A — this v2-only renderer rejects a marine_evidence_v3 packet and never reads its policy.
    it 'returns nil for a marine_evidence_v3 packet (v2-only, never reads presentation_policy)' do
      v3 = deep_freeze(price_packet(freeze: false).merge(
                         evidence_version: 'marine_evidence_v3',
                         presentation_policy: { tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code' }
                       ))
      expect(renderer.call(packet: v3)).to be_nil
    end

    it 'does not surface the authoritative source / policy_version / checked_at in the customer text' do
      text = renderer.call(packet: price_packet)

      expect(text).not_to match(/catalog_price_repository|price-display-v1|2026-09-30|checked_at|policy/i)
    end
  end
end
