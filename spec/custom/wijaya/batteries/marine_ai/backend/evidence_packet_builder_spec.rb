# frozen_string_literal: true

require 'rails_helper'

# Phase 1 (Opsi B) — marine_evidence_v2 PRODUCT Evidence Packet builder. A CLOSED, FAIL-CLOSED
# validator: closed keys/enums, hard bounds, deep-frozen, product-only (no ERP customer/payment
# blocks), no null facts. Execution authorization is backend-policy-owned: the COMPLETE top-level
# intents set must be the exact ExecutionPolicy-authorized array (Phase 1: exactly ["price"]), and
# scenario carries only provenance ({ key, intents }) — never capabilities. A malformed
# programmer-supplied evidence input raises InvalidEvidenceInputError and never yields a partial
# packet. Clock injected. Nothing touches a provider, DB, or state.
RSpec.describe Marine::Backend::EvidencePacketBuilder do
  subject(:builder) { described_class.new(clock: clock) }

  let(:clock) { -> { Time.utc(2026, 9, 30, 12, 0, 0) } }
  let(:invalid_error) { described_class::InvalidEvidenceInputError }
  let(:price_fact) do
    {
      canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' },
      display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' },
      policy_version: 'price-display-v1', source: 'catalog_price_repository', checked_at: '2026-09-30T12:00:00Z'
    }
  end
  let(:stock_fact) { { status: 'available', source: 'stock_repository', checked_at: '2026-09-30T12:00:00Z' } }

  let(:variant_slot) { { code: 'BD-4', display_name: nil, attributes: { 'Colour' => '4' }, resolution_status: 'resolved', source: 'marine_catalog' } }

  # The Phase-1 canonical valid input: an exact-price packet over a single resolved variant slot.
  def evidence_input(overrides = {})
    {
      scenario: { key: 'scenario_8' },
      intents: %w[price],
      customer_language: 'id',
      response_goals: %w[answer_price],
      validated_slots: {
        product: { code: 'BD', name: 'Santorini', source: 'marine_catalog' },
        variant: variant_slot
      },
      facts: { price: price_fact },
      missing_slots: [],
      variant_candidates: []
    }.merge(overrides)
  end

  # A minimal price-only valid input (single resolved variant slot) for fact-shape mutation tests.
  def price_input(overrides = {})
    {
      scenario: { key: 'scenario_5' },
      intents: %w[price], customer_language: 'id', response_goals: %w[answer_price],
      validated_slots: { variant: variant_slot }, facts: { price: price_fact },
      missing_slots: [], variant_candidates: []
    }.merge(overrides)
  end

  describe 'a resolved exact-price packet' do
    subject(:packet) { builder.build(evidence_input: evidence_input) }

    it 'carries the frozen v2 version, injected generated_at, provenance scenario, the price fact, and constraints' do
      expect(packet[:evidence_version]).to eq('marine_evidence_v2')
      expect(packet[:generated_at]).to eq('2026-09-30T12:00:00Z')
      expect(packet[:scenario]).to eq(key: 'scenario_8', intents: %w[price])
      expect(packet[:scenario]).not_to have_key(:capabilities)
      expect(packet[:facts][:price][:display][:amount]).to eq('12.500')
      expect(packet[:response_constraints]).to eq(max_paragraphs: 2, role: 'marine_sales_assistant', handoff_self_reference: true)
      expect(packet[:customer_language]).to eq('id')
    end

    it 'uses only closed keys and NEVER emits ERP customer/payment blocks' do
      expect(packet.keys).to match_array(%i[
                                           evidence_version generated_at response_goals scenario validated_slots
                                           facts missing_slots variant_candidates prohibited_claims response_constraints customer_language
                                         ])
      expect(packet).not_to have_key(:customer_resolution)
      expect(packet).not_to have_key(:payment_policy)
    end

    it 'omits price from prohibited_claims when the price fact is present but keeps stock prohibited' do
      expect(packet[:prohibited_claims]).to contain_exactly('exact_stock_quantity', 'warehouse_location', 'delivery_date', 'unverified_discount',
                                                            'stock')
    end

    it 'is deeply frozen and within the 16 KiB serialized ceiling' do
      expect(packet).to be_frozen
      expect(packet[:facts][:price][:canonical]).to be_frozen
      expect(JSON.generate(packet).bytesize).to be <= described_class::MAX_PACKET_BYTES
    end
  end

  describe 'whole-set execution-policy authorization (single authorized product intent, no dedupe/sort)' do
    it 'accepts exactly the ["price"] top-level intents set' do
      expect { builder.build(evidence_input: evidence_input(intents: %w[price])) }.not_to raise_error
    end

    it 'rejects an unauthorized / mixed / duplicated / reordered top-level intents set' do
      expect do
        builder.build(evidence_input: evidence_input(intents: %w[catalog], response_goals: %w[answer_product_overview], facts: {}))
      end.to raise_error(invalid_error)
      expect { builder.build(evidence_input: evidence_input(intents: %w[price stock])) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: evidence_input(intents: %w[price price])) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: evidence_input(intents: %w[not_an_intent])) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: evidence_input(intents: 'price')) }.to raise_error(invalid_error)
    end
  end

  describe 'omission rules (unresolved slot -> no guessed/null facts)' do
    subject(:packet) do
      builder.build(evidence_input: evidence_input(
        response_goals: %w[clarify_product], validated_slots: {}, facts: {}, missing_slots: %w[product]
      ))
    end

    it 'omits the facts entirely and forbids price+stock claims' do
      expect(packet[:facts]).to eq({})
      expect(packet[:validated_slots]).to eq({})
      expect(packet[:prohibited_claims]).to include('price', 'stock')
      expect(packet[:missing_slots]).to eq(%w[product])
    end
  end

  describe 'bounds' do
    it 'caps attributes at 16 and each key/value at 80 bytes' do
      big_attrs = (1..20).each_with_object({}) { |i, acc| acc["k#{i}"] = 'v' }
      big_attrs['long'] = 'x' * 200
      packet = builder.build(evidence_input: price_input(
        validated_slots: { variant: { code: 'BD-4', attributes: big_attrs, resolution_status: 'resolved', source: 'marine_catalog' } }
      ))
      attrs = packet[:validated_slots][:variant][:attributes]
      expect(attrs.size).to be <= 16
      expect(attrs.values.map(&:bytesize).max).to be <= 80
    end
  end

  describe 'stock fact (Phase 5 — binary availability only)' do
    def stock_build(fact)
      builder.build(evidence_input: {
                      scenario: { key: 'scenario_8' }, intents: %w[stock], customer_language: 'id',
                      response_goals: %w[answer_stock],
                      validated_slots: { product: { code: 'BD', name: 'Santorini', source: 'marine_catalog' }, variant: variant_slot },
                      facts: { stock: fact }, missing_slots: [], variant_candidates: []
                    })
    end

    it 'builds both binary states and carries ONLY status/source/checked_at (no numeric inventory)' do
      available = stock_build(stock_fact)
      expect(available[:facts][:stock]).to eq(status: 'available', source: 'stock_repository', checked_at: '2026-09-30T12:00:00Z')
      expect(available[:facts][:stock].keys).to contain_exactly(:status, :source, :checked_at)
      unavailable = stock_build(stock_fact.merge(status: 'unavailable'))
      expect(unavailable[:facts][:stock][:status]).to eq('unavailable')
      # The serialized FACT never carries a quantity/qty/warehouse/bin token or any numeric inventory
      # (the packet's prohibited_claims labels are negative constraints, so scope the check to facts).
      expect(JSON.generate(available[:facts])).not_to match(/actual_qty|quantity|warehouse|\bbin\b|\bqty\b/)
      expect(available[:facts][:stock].values.none?(Numeric)).to be(true)
    end

    it 'rejects an unknown stock status and any extra numeric/quantity key' do
      expect { stock_build(stock_fact.merge(status: 'low')) }.to raise_error(invalid_error)
      expect { stock_build(stock_fact.merge(actual_qty: 20)) }.to raise_error(invalid_error)
      expect { stock_build(stock_fact.merge(quantity: 20)) }.to raise_error(invalid_error)
    end
  end

  describe 'price_range fact (Phase 5 — family-level range, formatter-reconstructed display)' do
    let(:range_canonical) { { family_code: 'BD', currency: 'IDR', min: '10000', max: '12500', uom: 'Yard' } }
    let(:range_display) { { currency: 'Rp', min: '10.000', max: '12.500', uom: 'yard' } }
    let(:range_fact) do
      { canonical: range_canonical, display: range_display,
        policy_version: 'price-display-v1', source: 'catalog_price_range_repository', checked_at: '2026-09-30T12:00:00Z' }
    end

    def range_build(fact_overrides = {}, input_overrides = {})
      builder.build(evidence_input: {
        scenario: { key: 'scenario_8' }, intents: %w[price_range], customer_language: 'id',
        response_goals: %w[answer_price_range],
        validated_slots: { product: { code: 'BD', name: 'Santorini', source: 'marine_catalog' } },
        facts: { price_range: range_fact.merge(fact_overrides) }, missing_slots: [], variant_candidates: []
      }.merge(input_overrides))
    end

    it 'builds a frozen price_range fact bound to the product slot, display reconstructed from the canonical' do
      packet = range_build
      expect(packet[:response_goals]).to eq(%w[answer_price_range])
      expect(packet[:facts][:price_range]).to eq(range_fact)
      expect(packet[:facts][:price_range]).to be_frozen
      expect(packet[:facts][:price_range][:canonical]).to be_frozen
    end

    it 'keeps equal endpoints exact and coherent (min == max)' do
      packet = range_build({ canonical: range_canonical.merge(min: '12500'), display: range_display.merge(min: '12.500') })
      expect(packet[:facts][:price_range][:display]).to eq(currency: 'Rp', min: '12.500', max: '12.500', uom: 'yard')
    end

    it 'rejects a forged display endpoint/currency/uom (display is never trusted)' do
      expect { range_build({ display: range_display.merge(min: '9.999') }) }.to raise_error(invalid_error)
      expect { range_build({ display: range_display.merge(max: '13.000') }) }.to raise_error(invalid_error)
      expect { range_build({ display: range_display.merge(currency: 'USD') }) }.to raise_error(invalid_error)
    end

    it 'rejects a forged source and an incoherent min > max' do
      expect { range_build({ source: 'catalog_price_repository' }) }.to raise_error(invalid_error)
      expect do
        range_build({ canonical: range_canonical.merge(min: '12500', max: '10000'),
                      display: range_display.merge(min: '12.500', max: '10.000') })
      end.to raise_error(invalid_error)
    end

    it 'rejects a non-UTC / malformed price_range checked_at (forged provenance fails closed)' do
      expect { range_build({ checked_at: '2026-09-30 12:00:00' }) }.to raise_error(invalid_error)
      expect { range_build({ checked_at: '2026-09-30T12:00:00+07:00' }) }.to raise_error(invalid_error)
    end

    it 'rejects a canonical family_code that does not match the product slot' do
      expect { range_build({ canonical: range_canonical.merge(family_code: 'ZZ') }) }.to raise_error(invalid_error)
    end

    it 'rejects a price_range fact with no product slot, or an incoherent goal/intent set' do
      expect { range_build({}, { validated_slots: {} }) }.to raise_error(invalid_error)
      expect { range_build({}, { response_goals: %w[answer_price] }) }.to raise_error(invalid_error)
      expect { range_build({}, { intents: %w[price] }) }.to raise_error(invalid_error)
    end
  end

  # Checkpoint A — the staged marine_evidence_v3 opt-in: a presentation_policy is carried OUTSIDE facts
  # and restricted to the answer_price_range packet. Absent policy => v2 (unchanged); present policy on
  # any other goal, or a malformed policy, fails closed. v2 packets never carry a presentation_policy.
  describe 'presentation_policy (marine_evidence_v3, answer_price_range only)' do
    let(:policy) { { tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code' } }
    let(:range_canonical) { { family_code: 'BD', currency: 'IDR', min: '10000', max: '12500', uom: 'Yard' } }
    let(:range_display) { { currency: 'Rp', min: '10.000', max: '12.500', uom: 'yard' } }
    let(:range_fact) do
      { canonical: range_canonical, display: range_display,
        policy_version: 'price-display-v1', source: 'catalog_price_range_repository', checked_at: '2026-09-30T12:00:00Z' }
    end

    def v3_build(policy_overrides = :unset, input_overrides = {})
      input = {
        scenario: { key: 'scenario_8' }, intents: %w[price_range], customer_language: 'id',
        response_goals: %w[answer_price_range],
        validated_slots: { product: { code: 'BD', name: 'Santorini', source: 'marine_catalog' } },
        facts: { price_range: range_fact }, missing_slots: [], variant_candidates: []
      }
      input[:presentation_policy] = (policy_overrides == :unset ? policy : policy_overrides) unless policy_overrides.nil?
      builder.build(evidence_input: input.merge(input_overrides))
    end

    it 'emits marine_evidence_v3 with the closed policy OUTSIDE facts, deeply frozen, facts unchanged' do
      packet = v3_build

      expect(packet[:evidence_version]).to eq('marine_evidence_v3')
      expect(packet[:presentation_policy]).to eq(tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code')
      expect(packet[:facts]).not_to have_key(:presentation_policy)
      expect(packet[:facts][:price_range]).to eq(range_fact)
      expect(packet[:presentation_policy]).to be_frozen
      expect(packet[:presentation_policy].values).to all(be_frozen)
    end

    it 'stays marine_evidence_v2 with NO presentation_policy when no policy is supplied' do
      packet = v3_build(nil)
      expect(packet[:evidence_version]).to eq('marine_evidence_v2')
      expect(packet).not_to have_key(:presentation_policy)
    end

    it 'rejects a presentation_policy on a non-range (answer_price) packet' do
      expect do
        builder.build(evidence_input: evidence_input(presentation_policy: policy))
      end.to raise_error(invalid_error)
    end

    it 'rejects a malformed policy (unknown value, missing key, extra key, non-hash)' do
      expect { v3_build(policy.merge(tone: 'snarky')) }.to raise_error(invalid_error)
      expect { v3_build(policy.merge(verbosity: 'verbose')) }.to raise_error(invalid_error)
      expect { v3_build(policy.merge(range_followup_mode: 'whatever')) }.to raise_error(invalid_error)
      expect { v3_build(policy.except(:tone)) }.to raise_error(invalid_error)
      expect { v3_build(policy.merge(surprise: 'x')) }.to raise_error(invalid_error)
      expect { v3_build('professional') }.to raise_error(invalid_error)
    end
  end

  describe 'fail-closed structural rejections' do
    it 'rejects an unknown top-level input key' do
      expect { builder.build(evidence_input: evidence_input(surprise: 1)) }.to raise_error(invalid_error)
    end

    it 'rejects an unknown or overflowing response goal' do
      expect { builder.build(evidence_input: evidence_input(response_goals: %w[answer_price not_a_goal])) }.to raise_error(invalid_error)
      expect do
        builder.build(evidence_input: evidence_input(
          response_goals: %w[answer_price answer_stock answer_product_overview clarify_product clarify_variant]
        ))
      end.to raise_error(invalid_error)
    end

    it 'rejects a scenario carrying a capabilities subkey as an unknown key' do
      expect { builder.build(evidence_input: evidence_input(scenario: { key: 'scenario_8', capabilities: %w[price] })) }.to raise_error(invalid_error)
    end

    it 'rejects a malformed scenario key' do
      expect do
        builder.build(evidence_input: evidence_input(scenario: { key: 'Scenario-8!' }))
      end.to raise_error(invalid_error)
    end

    it 'rejects an unknown fact key and an unknown nested slot key' do
      expect { builder.build(evidence_input: price_input(facts: { price: price_fact, mystery: {} })) }.to raise_error(invalid_error)
      expect do
        builder.build(evidence_input: price_input(validated_slots: { variant: variant_slot.merge(surprise: 1) }))
      end.to raise_error(invalid_error)
    end

    it 'rejects a wrong slot source' do
      expect do
        builder.build(evidence_input: price_input(validated_slots: { variant: variant_slot.merge(source: 'live_erp') }))
      end.to raise_error(invalid_error)
    end
  end

  describe 'fail-closed fact-shape rejections' do
    it 'rejects a wrong price source / policy_version' do
      expect { builder.build(evidence_input: price_input(facts: { price: price_fact.merge(source: 'somewhere') })) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: price_input(facts: { price: price_fact.merge(policy_version: 'v2') })) }.to raise_error(invalid_error)
    end

    it 'rejects a non-UTC / malformed checked_at' do
      expect do
        builder.build(evidence_input: price_input(facts: { price: price_fact.merge(checked_at: '2026-09-30 12:00:00') }))
      end.to raise_error(invalid_error)
      expect do
        builder.build(evidence_input: price_input(facts: { price: price_fact.merge(checked_at: '2026-09-30T12:00:00+07:00') }))
      end.to raise_error(invalid_error)
    end

    it 'rejects a canonical variant_code that does not match the resolved variant slot' do
      drifted = price_fact.merge(canonical: price_fact[:canonical].merge(variant_code: 'BD-9'),
                                 display: price_fact[:display].merge(product: 'BD-9'))
      expect { builder.build(evidence_input: price_input(facts: { price: drifted })) }.to raise_error(invalid_error)
    end

    it 'rejects a display block inconsistent with the canonical (product / uom drift)' do
      bad_product = price_fact.merge(display: price_fact[:display].merge(product: 'BD-4X'))
      bad_uom = price_fact.merge(display: price_fact[:display].merge(uom: 'metre'))
      expect { builder.build(evidence_input: price_input(facts: { price: bad_product })) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: price_input(facts: { price: bad_uom })) }.to raise_error(invalid_error)
    end

    it 'rejects a float / negative price rate but accepts an integer rate' do
      float_rate = price_fact.merge(canonical: price_fact[:canonical].merge(price_list_rate: 12_500.0))
      neg_rate = price_fact.merge(canonical: price_fact[:canonical].merge(price_list_rate: -5))
      expect { builder.build(evidence_input: price_input(facts: { price: float_rate })) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: price_input(facts: { price: neg_rate })) }.to raise_error(invalid_error)
      int_rate = price_fact.merge(canonical: price_fact[:canonical].merge(price_list_rate: 12_500))
      expect(builder.build(evidence_input: price_input(facts: { price: int_rate }))[:facts][:price][:canonical][:price_list_rate]).to eq(12_500)
    end

    it 'rejects a price fact with no resolved variant slot' do
      expect { builder.build(evidence_input: price_input(validated_slots: {})) }.to raise_error(invalid_error)
    end
  end

  describe 'fail-closed fact/intent/goal coherence (preserved as extra defense)' do
    it 'rejects a price fact without the answer_price goal' do
      expect { builder.build(evidence_input: price_input(response_goals: %w[clarify_product])) }.to raise_error(invalid_error)
    end

    it 'rejects an answer_price goal without a price fact' do
      input = { scenario: { key: 'scenario_5' }, intents: %w[price], response_goals: %w[answer_price],
                validated_slots: {}, facts: {}, missing_slots: [], variant_candidates: [] }
      expect { builder.build(evidence_input: input) }.to raise_error(invalid_error)
    end

    it 'rejects a non-price (stock) fact riding in an authorized price packet' do
      # intents is the exact ["price"] set (so the whole-set gate passes), but a stock fact is still
      # rejected by the preserved per-fact coherence guard — extra defense in depth.
      input = { scenario: { key: 'scenario_5' }, intents: %w[price], response_goals: %w[answer_price],
                validated_slots: { variant: variant_slot }, facts: { price: price_fact, stock: stock_fact },
                missing_slots: [], variant_candidates: [] }
      expect { builder.build(evidence_input: input) }.to raise_error(invalid_error)
    end

    it 'rejects an overflowing variant_candidates list' do
      expect { builder.build(evidence_input: price_input(variant_candidates: %w[a b c d e f g])) }.to raise_error(invalid_error)
    end
  end

  it 'never emits a nil customer_language key' do
    # A factless handoff packet (no price fact) may omit the language entirely.
    input = { scenario: { key: 'scenario_8' }, intents: %w[price],
              customer_language: nil, response_goals: %w[handoff],
              validated_slots: {}, facts: {}, missing_slots: [], variant_candidates: [] }
    packet = builder.build(evidence_input: input)
    expect(packet).not_to have_key(:customer_language)
  end

  describe 'price display authority (formatter-reconstructed, immutable)' do
    let(:formatter) { Marine::Catalog::PriceDisplayFormatter.new }

    def display_for(canonical, locale)
      formatter.format(
        descriptor: { kind: :price_available, variant_code: canonical[:variant_code], price_list_rate: canonical[:price_list_rate],
                      currency: canonical[:currency], uom: canonical[:uom] },
        locale: locale
      ).envelope[:display]
    end

    it 'reconstructs the id display envelope from the canonical facts' do
      packet = builder.build(evidence_input: price_input)
      expect(packet[:facts][:price][:display]).to eq(product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard')
    end

    it 'reconstructs the en display envelope from the canonical facts' do
      canonical = { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' }
      fact = price_fact.merge(canonical: canonical, display: display_for(canonical, 'en'))
      packet = builder.build(evidence_input: price_input(customer_language: 'en', facts: { price: fact }))
      expect(packet[:customer_language]).to eq('en')
      expect(packet[:facts][:price][:display]).to eq(product: 'BD-4', currency: 'IDR', amount: '12,500', uom: 'yard')
    end

    it 'rejects a forged display amount while the canonical rate is unchanged' do
      forged = price_fact.merge(display: price_fact[:display].merge(amount: '99.999'))
      expect { builder.build(evidence_input: price_input(facts: { price: forged })) }.to raise_error(invalid_error)
    end

    it 'rejects a forged display currency while the canonical currency is unchanged' do
      forged = price_fact.merge(display: price_fact[:display].merge(currency: 'USD'))
      expect { builder.build(evidence_input: price_input(facts: { price: forged })) }.to raise_error(invalid_error)
    end

    it 'requires a supported formatter locale for a price fact (unsupported / missing fails closed)' do
      expect { builder.build(evidence_input: price_input(customer_language: 'fr')) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: price_input(customer_language: nil)) }.to raise_error(invalid_error)
    end

    it 'accepts integer, BigDecimal, and string canonical rates with a formatter-consistent display' do
      [12_500, BigDecimal(12_500), '12500'].each do |rate|
        canonical = { variant_code: 'BD-4', currency: 'IDR', price_list_rate: rate, uom: 'Yard' }
        fact = price_fact.merge(canonical: canonical, display: display_for(canonical, 'id'))
        packet = builder.build(evidence_input: price_input(facts: { price: fact }))
        expect(packet[:facts][:price][:canonical][:price_list_rate]).to eq(rate)
      end
    end
  end

  describe 'a bounded product_listing packet (Phase 3)' do
    let(:listing_fact) do
      {
        products: [{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }],
        returned_count: 2, total_count: 2, complete: true,
        source: 'catalog_listing_repository', checked_at: '2026-09-30T12:00:00Z'
      }
    end

    # A fully-described listing fact (every product carries a nonblank description) — the only shape a
    # valid answer_product_information packet may carry.
    let(:described_listing_fact) do
      listing_fact.merge(products: [{ code: 'AAA', name: 'Alpha', description: 'Soft cotton' },
                                    { code: 'BBB', name: 'Bravo', description: 'Warm wool' }])
    end

    def listing_input(overrides = {})
      {
        scenario: { key: 'scenario_9' }, intents: %w[product_listing], customer_language: 'id',
        response_goals: %w[answer_product_listing], validated_slots: {}, facts: { product_listing: listing_fact },
        missing_slots: [], variant_candidates: []
      }.merge(overrides)
    end

    # A valid answer_product_information input over a fully-described listing fact.
    def info_input(overrides = {})
      listing_input({ intents: %w[product_information], response_goals: %w[answer_product_information],
                      facts: { product_listing: described_listing_fact } }.merge(overrides))
    end

    it 'builds a complete names-only listing with exact completeness metadata, deep-frozen and within the ceiling' do
      packet = builder.build(evidence_input: listing_input)
      listing = packet[:facts][:product_listing]
      expect(listing[:products]).to eq([{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }])
      expect(listing[:returned_count]).to eq(2)
      expect(listing[:total_count]).to eq(2)
      expect(listing[:complete]).to be(true)
      expect(listing[:source]).to eq('catalog_listing_repository')
      expect(packet[:scenario]).to eq(key: 'scenario_9', intents: %w[product_listing])
      expect(packet[:prohibited_claims]).to include('price', 'stock')
      expect(packet).to be_frozen
      expect(JSON.generate(packet).bytesize).to be <= described_class::MAX_PACKET_BYTES
    end

    it 'authorizes ["product_listing"] and ["product_information"] but rejects mixed/duplicated listing sets' do
      expect { builder.build(evidence_input: listing_input) }.not_to raise_error
      expect { builder.build(evidence_input: info_input) }.not_to raise_error
      expect { builder.build(evidence_input: listing_input(intents: %w[price product_listing])) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: listing_input(intents: %w[product_listing product_listing])) }.to raise_error(invalid_error)
    end

    it 'carries total_count > returned_count when not complete' do
      partial = listing_fact.merge(returned_count: 2, total_count: 9, complete: false)
      packet = builder.build(evidence_input: listing_input(facts: { product_listing: partial }))
      expect(packet[:facts][:product_listing][:complete]).to be(false)
      expect(packet[:facts][:product_listing][:total_count]).to eq(9)
    end

    it 'omits total_count entirely when it is absent (nil) and the page is not complete' do
      partial = listing_fact.merge(total_count: nil, complete: false)
      packet = builder.build(evidence_input: listing_input(facts: { product_listing: partial }))
      expect(packet[:facts][:product_listing]).not_to have_key(:total_count)
      expect(packet[:facts][:product_listing][:complete]).to be(false)
    end

    it 'fails closed on an inexact completeness/count claim' do
      bad_count = listing_fact.merge(returned_count: 5) # != products.length
      wrong_total = listing_fact.merge(total_count: 3, complete: true) # complete but total != returned
      small_total = listing_fact.merge(total_count: 2, complete: false) # has_more but total not > returned
      expect { builder.build(evidence_input: listing_input(facts: { product_listing: bad_count })) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: listing_input(facts: { product_listing: wrong_total })) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: listing_input(facts: { product_listing: small_total })) }.to raise_error(invalid_error)
    end

    it 'fails closed on duplicate product codes or an overflowing page' do
      dupes = listing_fact.merge(products: [{ code: 'AAA', name: 'A' }, { code: 'AAA', name: 'A2' }], returned_count: 2)
      overflow_products = (1..(described_class::MAX_LISTING_PRODUCTS + 1)).map { |i| { code: "C#{i}", name: "N#{i}" } }
      overflow = listing_fact.merge(products: overflow_products, returned_count: overflow_products.length, total_count: overflow_products.length)
      expect { builder.build(evidence_input: listing_input(facts: { product_listing: dupes })) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: listing_input(facts: { product_listing: overflow })) }.to raise_error(invalid_error)
    end

    it 'requires a nonblank description on EVERY product under answer_product_information' do
      packet = builder.build(evidence_input: info_input)
      descriptions = packet[:facts][:product_listing][:products].map { |product| product[:description] }
      expect(descriptions).to eq(['Soft cotton', 'Warm wool'])
    end

    it 'fails closed on an answer_product_information product missing (or blank) a description' do
      missing = described_listing_fact.merge(
        products: [{ code: 'AAA', name: 'Alpha', description: 'Soft cotton' }, { code: 'BBB', name: 'Bravo' }]
      )
      blank = described_listing_fact.merge(
        products: [{ code: 'AAA', name: 'Alpha', description: 'Soft cotton' }, { code: 'BBB', name: 'Bravo', description: '   ' }]
      )
      expect { builder.build(evidence_input: info_input(facts: { product_listing: missing })) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: info_input(facts: { product_listing: blank })) }.to raise_error(invalid_error)
    end

    it 'forbids a per-product description on a names-only answer_product_listing' do
      described = listing_fact.merge(
        products: [{ code: 'AAA', name: 'Alpha', description: 'Soft cotton' }, { code: 'BBB', name: 'Bravo' }]
      )
      expect { builder.build(evidence_input: listing_input(facts: { product_listing: described })) }.to raise_error(invalid_error)
    end

    it 'enforces listing fact/goal/intent coherence' do
      no_goal = listing_input(response_goals: %w[handoff])
      no_fact = listing_input(facts: {})
      wrong_intent = { scenario: { key: 'scenario_9' }, intents: %w[price], customer_language: 'id',
                       response_goals: %w[answer_product_listing], validated_slots: {},
                       facts: { product_listing: listing_fact }, missing_slots: [], variant_candidates: [] }
      expect { builder.build(evidence_input: no_goal) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: no_fact) }.to raise_error(invalid_error)
      expect { builder.build(evidence_input: wrong_intent) }.to raise_error(invalid_error)
    end
  end
end
