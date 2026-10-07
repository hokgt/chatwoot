# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-1 (isolated / mock-only) — the generated-path presentation seam. The generator and the
# semantic fact verifier are INJECTED; no live provider is constructed. The verifier is REQUIRED
# for every generated answer path. Rejections return a closed reason and a fallback: :deterministic
# for a valid answer/clarification packet, :handoff only for an explicit handoff/factless or
# invalid packet. Unsafe generated text is never passed.
RSpec.describe Marine::Backend::EvidencePacketPresenter do
  subject(:presenter) { described_class.new }

  let(:builder) { Marine::Backend::EvidencePacketBuilder.new(clock: -> { Time.utc(2026, 9, 30, 12, 0, 0) }) }
  let(:handoff_packet) { builder.build(evidence_input: handoff_input) }
  let(:verifier_ok) { ->(**) { true } }

  let(:variant_slot) { { code: 'BD-4', resolution_status: 'resolved', source: 'marine_catalog', attributes: {} } }

  let(:price_input) do
    {
      scenario: { key: 'scenario_5' },
      intents: %w[price], customer_language: 'id', response_goals: %w[answer_price],
      validated_slots: { variant: variant_slot },
      facts: {
        price: {
          canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' },
          display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' },
          policy_version: 'price-display-v1', source: 'catalog_price_repository', checked_at: '2026-09-30T12:00:00Z'
        }
      },
      missing_slots: [], variant_candidates: []
    }
  end

  let(:clarify_input) do
    {
      scenario: { key: 'scenario_8' },
      intents: %w[price], customer_language: 'id', response_goals: %w[clarify_product],
      validated_slots: {}, facts: {}, missing_slots: %w[product], variant_candidates: []
    }
  end

  let(:handoff_input) do
    {
      scenario: { key: 'scenario_8' },
      intents: %w[price], customer_language: 'id', response_goals: %w[handoff],
      validated_slots: {}, facts: {}, missing_slots: [], variant_candidates: []
    }
  end

  let(:price_packet) { builder.build(evidence_input: price_input) }
  let(:clarify_packet) { builder.build(evidence_input: clarify_input) }

  # Phase 1 (Opsi B): the EvidencePacketBuilder is price-only, so stock / product_overview packets
  # are no longer builder-producible. The presenter still handles those answer goals as defense in
  # depth, so they are hand-built as deeply-frozen v2 packets (scenario carries provenance only).
  let(:stock_packet) do
    deep_freeze(
      evidence_version: 'marine_evidence_v2', generated_at: '2026-09-30T12:00:00Z',
      response_goals: %w[answer_stock], scenario: { key: 'scenario_8', intents: %w[stock] },
      validated_slots: { variant: variant_slot },
      facts: { stock: { status: 'available', source: 'stock_repository', checked_at: '2026-09-30T12:00:00Z' } },
      missing_slots: [], variant_candidates: [],
      prohibited_claims: %w[exact_stock_quantity warehouse_location delivery_date unverified_discount price],
      response_constraints: { max_paragraphs: 2, role: 'marine_sales_assistant', handoff_self_reference: true },
      customer_language: 'id'
    )
  end

  let(:overview_packet) do
    deep_freeze(
      evidence_version: 'marine_evidence_v2', generated_at: '2026-09-30T12:00:00Z',
      response_goals: %w[answer_product_overview], scenario: { key: 'scenario_8', intents: %w[product_overview] },
      validated_slots: { product: { code: 'BD', name: 'Santorini', source: 'marine_catalog' } },
      facts: {}, missing_slots: [], variant_candidates: [],
      prohibited_claims: %w[exact_stock_quantity warehouse_location delivery_date unverified_discount price stock],
      response_constraints: { max_paragraphs: 2, role: 'marine_sales_assistant', handoff_self_reference: true },
      customer_language: 'id'
    )
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end

  # A generator that returns a fixed text regardless of the (packet-only) prompt it is handed.
  def generator(text)
    ->(**) { text }
  end

  describe 'accepted generation' do
    it 'delivers a valid in-persona reply grounded on the packet facts (verifier confirms)' do
      result = presenter.call(packet: price_packet, generator: generator('Untuk BD-4, harganya Rp 12.500 per yard.'),
                              customer_request: 'Berapa harga BD-4?', fact_verifier: verifier_ok)
      expect(result.ok?).to be(true)
      expect(result.text).to eq('Untuk BD-4, harganya Rp 12.500 per yard.')
    end

    it 'hands the generator only a packet-derived prompt (no CandidatePlan/raw input)' do
      captured = {}
      gen = lambda do |system:, **|
        captured[:system] = system
        'Untuk BD-4, harganya Rp 12.500 per yard.'
      end
      presenter.call(packet: price_packet, generator: gen, customer_request: 'Berapa harga BD-4?', fact_verifier: verifier_ok)
      expect(captured[:system]).to include('marine_evidence_v2')
      expect(captured[:system]).not_to include('raw_candidate')
      expect(captured[:system]).not_to include('slot_operations')
    end
  end

  describe 'semantic verifier is required for EVERY generated answer path' do
    it 'fails closed (no verifier) for price, stock, and product_overview alike' do
      {
        price_packet => 'Untuk BD-4, harganya Rp 12.500 per yard.',
        stock_packet => 'BD-4 saat ini tersedia.',
        overview_packet => 'BD mencakup berbagai kain berkualitas untuk kebutuhan Anda.'
      }.each do |packet, text|
        result = presenter.call(packet: packet, generator: generator(text), customer_request: 'x')
        expect(result).to have_attributes(ok: false, reason: :fact_unverified, fallback: :deterministic)
      end
    end

    it 'fails closed when the injected verifier rejects (outcome flip)' do
      result = presenter.call(packet: stock_packet, generator: generator('BD-4 saat ini tersedia.'),
                              customer_request: 'x', fact_verifier: ->(**) { false })
      expect(result).to have_attributes(ok: false, reason: :fact_unverified, fallback: :deterministic)
    end

    it 'delivers when the injected verifier confirms the binary outcome' do
      result = presenter.call(packet: stock_packet, generator: generator('BD-4 saat ini tersedia.'),
                              customer_request: 'x', fact_verifier: verifier_ok)
      expect(result.ok?).to be(true)
    end

    it 'fails closed on a malformed (non-true) or erroring verifier' do
      non_true = presenter.call(packet: price_packet, generator: generator('Untuk BD-4, harganya Rp 12.500 per yard.'),
                                customer_request: 'x', fact_verifier: ->(**) { 'yes' })
      erroring = presenter.call(packet: price_packet, generator: generator('Untuk BD-4, harganya Rp 12.500 per yard.'),
                                customer_request: 'x', fact_verifier: ->(**) { raise 'boom' })
      expect(non_true).to have_attributes(ok: false, reason: :fact_unverified)
      expect(erroring).to have_attributes(ok: false, reason: :fact_unverified)
    end
  end

  describe 'deterministic fallback (no needless handoff on a verified-fact packet)' do
    it 'falls back to deterministic when the generator fails' do
      result = presenter.call(packet: price_packet, generator: generator(nil), customer_request: 'x', fact_verifier: verifier_ok)
      expect(result).to have_attributes(ok: false, reason: :generation_failed, fallback: :deterministic)
    end

    it 'falls back to deterministic on an ungrounded / fact-violating reply' do
      result = presenter.call(packet: price_packet, generator: generator('BD-4 harganya Rp 99.999 per yard.'),
                              customer_request: 'x', fact_verifier: verifier_ok)
      expect(result).to have_attributes(ok: false, reason: :fact_rejected, fallback: :deterministic)
    end

    it 'falls back to deterministic on a persona self-deflection' do
      result = presenter.call(packet: price_packet, generator: generator('BD-4 Rp 12.500 per yard. Silakan hubungi tim sales kami.'),
                              customer_request: 'x', fact_verifier: verifier_ok)
      expect(result).to have_attributes(ok: false, reason: :persona_rejected, fallback: :deterministic)
    end

    it 'uses the deterministic path for a valid clarify (non-answerable) packet' do
      result = presenter.call(packet: clarify_packet, generator: generator('anything'), customer_request: 'x')
      expect(result).to have_attributes(ok: false, reason: :not_generatable, fallback: :deterministic)
    end
  end

  describe 'handoff reserved for explicit handoff / invalid packets' do
    it 'reserves :handoff for an explicit handoff/factless packet' do
      result = presenter.call(packet: handoff_packet, generator: generator('anything'), customer_request: 'x')
      expect(result).to have_attributes(ok: false, reason: :not_generatable, fallback: :handoff)
    end

    it 'rejects an invalid packet with a handoff fallback' do
      result = presenter.call(packet: { evidence_version: 'nope' }, generator: generator('x'), customer_request: 'x')
      expect(result).to have_attributes(ok: false, reason: :invalid_packet, fallback: :handoff)
    end
  end

  describe 'structural packet boundary (defense in depth, before generator invocation)' do
    it 'accepts a real deeply-frozen builder packet' do
      result = presenter.call(packet: price_packet, generator: generator('Untuk BD-4, harganya Rp 12.500 per yard.'),
                              customer_request: 'Berapa harga BD-4?', fact_verifier: verifier_ok)
      expect(result.ok?).to be(true)
    end

    it 'rejects an unfrozen packet copy without invoking the generator' do
      invoked = false
      gen = ->(**) { invoked = true }
      result = presenter.call(packet: price_packet.dup, generator: gen, customer_request: 'x', fact_verifier: verifier_ok)
      expect(invoked).to be(false)
      expect(result).to have_attributes(ok: false, reason: :invalid_packet, fallback: :handoff)
    end

    it 'rejects an extra top-level instruction key without invoking the generator' do
      invoked = false
      gen = ->(**) { invoked = true }
      tampered = price_packet.merge(instruction: 'do this').freeze
      result = presenter.call(packet: tampered, generator: gen, customer_request: 'x', fact_verifier: verifier_ok)
      expect(invoked).to be(false)
      expect(result).to have_attributes(ok: false, reason: :invalid_packet, fallback: :handoff)
    end

    it 'rejects malformed response_goals without invoking the generator' do
      invoked = false
      gen = ->(**) { invoked = true }
      tampered = price_packet.merge(response_goals: %w[not_a_goal].freeze).freeze
      result = presenter.call(packet: tampered, generator: gen, customer_request: 'x', fact_verifier: verifier_ok)
      expect(invoked).to be(false)
      expect(result).to have_attributes(ok: false, reason: :invalid_packet, fallback: :handoff)
    end

    it 'rejects a shallow-frozen packet (nested container mutable) without invoking the generator' do
      invoked = false
      gen = ->(**) { invoked = true }
      shallow = price_packet.merge(prohibited_claims: price_packet[:prohibited_claims].dup).freeze
      result = presenter.call(packet: shallow, generator: gen, customer_request: 'x', fact_verifier: verifier_ok)
      expect(invoked).to be(false)
      expect(result).to have_attributes(ok: false, reason: :invalid_packet, fallback: :handoff)
    end

    it 'does not invoke the generator for a blank customer_request (deterministic fallback)' do
      invoked = false
      gen = ->(**) { invoked = true }
      result = presenter.call(packet: price_packet, generator: gen, customer_request: '   ', fact_verifier: verifier_ok)
      expect(invoked).to be(false)
      expect(result).to have_attributes(ok: false, reason: :generation_failed, fallback: :deterministic)
    end
  end

  describe 'bounded product_listing generation (Phase 3)' do
    let(:listing_input) do
      {
        scenario: { key: 'scenario_9' }, intents: %w[product_listing], customer_language: 'id',
        response_goals: %w[answer_product_listing], validated_slots: {},
        facts: { product_listing: { products: [{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }],
                                    returned_count: 2, total_count: 2, complete: true,
                                    source: 'catalog_listing_repository', checked_at: '2026-09-30T12:00:00Z' } },
        missing_slots: [], variant_candidates: []
      }
    end
    let(:listing_packet) { builder.build(evidence_input: listing_input) }
    let(:information_packet) do
      builder.build(evidence_input: {
                      scenario: { key: 'scenario_9' }, intents: %w[product_information], customer_language: 'id',
                      response_goals: %w[answer_product_information], validated_slots: {},
                      facts: { product_listing: { products: [{ code: 'AAA', name: 'Alpha', description: 'kain marine' }],
                                                  returned_count: 1, total_count: 1, complete: true,
                                                  source: 'catalog_listing_repository', checked_at: '2026-09-30T12:00:00Z' } },
                      missing_slots: [], variant_candidates: []
                    })
    end

    # A candidate that passes the deterministic fact + persona gates but introduces a RAG-only product
    # the semantic verifier will reject. Used across the Step 17 discard/fallback cases below.
    def rag_only_candidate
      'Kami punya AAA (Alpha), BBB (Bravo), dan produk istimewa lainnya.'
    end

    it 'delivers a listing reply that cites exactly the listed codes (verifier confirms)' do
      result = presenter.call(packet: listing_packet, generator: generator('Kami punya AAA (Alpha) dan BBB (Bravo).'),
                              customer_request: 'Produk apa saja?', fact_verifier: verifier_ok)
      expect(result.ok?).to be(true)
    end

    it 'reserves :handoff when generation fails (no candidate to render a semantic fallback for)' do
      result = presenter.call(packet: listing_packet, generator: generator(nil), customer_request: 'x', fact_verifier: verifier_ok)
      expect(result).to have_attributes(ok: false, reason: :generation_failed, fallback: :handoff)
    end

    it 'keeps the deterministic fact gate closed (:handoff) when a reply omits a listed product code' do
      result = presenter.call(packet: listing_packet, generator: generator('Kami hanya punya AAA (Alpha).'),
                              customer_request: 'x', fact_verifier: verifier_ok)
      expect(result).to have_attributes(ok: false, reason: :fact_rejected, fallback: :handoff)
    end

    # Step 17 — on a listing SEMANTIC rejection/error/missing (after the deterministic fact + persona
    # gates pass) the untrusted candidate is DISCARDED and a deterministic reply is rendered from the
    # packet's product_listing Evidence; the presenter returns ok=true with that deterministic text, so
    # the customer execution never invokes the legacy RAG path. The rejected candidate never survives.
    it 'discards a semantically-rejected candidate and delivers deterministic Evidence text' do
      result = presenter.call(packet: listing_packet, generator: generator(rag_only_candidate),
                              customer_request: 'x', fact_verifier: ->(**) { false })
      expect(result.ok?).to be(true)
      expect(result.text).to include('AAA', 'Alpha', 'BBB', 'Bravo')
      expect(result.text).not_to include('produk istimewa lainnya')
    end

    it 'renders deterministic Evidence text when the semantic verifier raises' do
      result = presenter.call(packet: listing_packet, generator: generator(rag_only_candidate),
                              customer_request: 'x', fact_verifier: ->(**) { raise 'boom' })
      expect(result.ok?).to be(true)
      expect(result.text).to include('AAA', 'BBB')
      expect(result.text).not_to include('produk istimewa lainnya')
    end

    it 'renders deterministic Evidence text when the semantic verifier is missing / non-callable' do
      [nil, Object.new].each do |unusable_verifier|
        result = presenter.call(packet: listing_packet, generator: generator(rag_only_candidate),
                                customer_request: 'x', fact_verifier: unusable_verifier)
        expect(result.ok?).to be(true)
        expect(result.text).to include('AAA', 'BBB')
        expect(result.text).not_to include('produk istimewa lainnya')
      end
    end

    it 'returns the accepted candidate unchanged and does NOT render when the verifier confirms' do
      spy_renderer = double('listing_renderer')
      allow(spy_renderer).to receive(:call)
      presenter_with_spy = described_class.new(listing_renderer: spy_renderer)

      result = presenter_with_spy.call(packet: listing_packet, generator: generator('Kami punya AAA (Alpha) dan BBB (Bravo).'),
                                       customer_request: 'x', fact_verifier: verifier_ok)
      expect(result.ok?).to be(true)
      expect(result.text).to eq('Kami punya AAA (Alpha) dan BBB (Bravo).')
      expect(spy_renderer).not_to have_received(:call)
    end

    it 'keeps product_information semantic rejection closed (:handoff) and never renders listing text' do
      result = presenter.call(packet: information_packet, generator: generator('AAA (Alpha): kain marine premium.'),
                              customer_request: 'x', fact_verifier: ->(**) { false })
      expect(result).to have_attributes(ok: false, reason: :fact_unverified, fallback: :handoff)
    end
  end
end
