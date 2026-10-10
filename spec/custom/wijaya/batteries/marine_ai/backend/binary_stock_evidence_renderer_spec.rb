# frozen_string_literal: true

require 'rails_helper'

# The deterministic binary-stock Evidence renderer. It renders an availability reply from a frozen
# marine_evidence_v2 answer_stock packet ALONE, through backend-owned localized id/en templates. Its
# only business-fact input is the authoritative/validated variant code (validated_slots[:variant][:code],
# marine_catalog-sourced) plus the binary stock status; it never reads a Model 2 candidate, the raw
# request/history, a provider / RAG / repository / DB / formatter, and never adds a quantity, warehouse /
# location, delivery / lead time, price / discount, or any qualitative claim. The authoritative stock
# source / checked_at are validated but NEVER surfaced in the customer text. It fails closed (nil) on a
# non-stock, multi-goal, wrong-version, crossed-policy, malformed, injected, mutable, or
# unsupported-language packet, and never raises.
RSpec.describe Marine::Backend::BinaryStockEvidenceRenderer do
  subject(:renderer) { described_class.new }

  def deep_freeze(value)
    case value
    when Hash then value.each { |key, child| deep_freeze(key.freeze) && deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end

  # The full real stock fact (mirrors the EvidencePacketBuilder contract). Overridable per key so the
  # fail-closed specs can drop/mangle any required area independently.
  def stock_fact(status: 'available', source: 'stock_repository', checked_at: '2026-09-30T12:00:00Z')
    { status: status, source: source, checked_at: checked_at }
  end

  # A deeply-frozen marine_evidence_v2 answer_stock packet carrying exactly the [:stock] fact over a
  # resolved marine_catalog variant slot. `freeze: false` yields a mutable pseudo-packet; `extra` merges
  # extra top-level keys (e.g. a crossed presentation_policy).
  def stock_packet(facts: :default, language: 'id', goals: %w[answer_stock], # rubocop:disable Metrics/ParameterLists -- a flexible packet fixture whose every contract area is independently overridable
                   scenario: { key: 'scenario_8', intents: %w[stock] },
                   validated_slots: { variant: { code: 'BD-4', resolution_status: 'resolved', attributes: {}, source: 'marine_catalog' } },
                   extra: {}, freeze: true)
    facts = { stock: stock_fact } if facts == :default
    packet = {
      evidence_version: 'marine_evidence_v2', generated_at: '2026-09-30T12:00:00Z',
      response_goals: goals, scenario: scenario, validated_slots: validated_slots,
      facts: facts, missing_slots: [], variant_candidates: [],
      prohibited_claims: %w[exact_stock_quantity warehouse_location delivery_date unverified_discount price],
      response_constraints: { max_paragraphs: 2, role: 'marine_sales_assistant', handoff_self_reference: true },
      customer_language: language
    }.merge(extra)
    freeze ? deep_freeze(packet) : packet
  end

  # A genuine builder-produced stock packet (the production path): the EvidencePacketBuilder DOES emit a
  # binary stock packet — ExecutionPolicy.product_authorized?(["stock"]) is true and answer_stock over a
  # resolved variant slot is coherent. Overridable where a positive case needs a different language/status.
  def built_packet(language: 'id', status: 'available')
    Marine::Backend::EvidencePacketBuilder.new(clock: -> { Time.utc(2026, 9, 30, 12, 0, 0) }).build(
      evidence_input: {
        scenario: { key: 'scenario_8' }, intents: %w[stock], customer_language: language,
        response_goals: %w[answer_stock],
        validated_slots: { variant: { code: 'BD-4', resolution_status: 'resolved', source: 'marine_catalog' } },
        facts: { stock: { status: status, source: 'stock_repository', checked_at: '2026-09-30T12:00:00Z' } },
        missing_slots: [], variant_candidates: []
      }
    )
  end

  describe 'authoritative binary-stock rendering from the Evidence alone' do
    it 'renders the id available template with the validated variant code (deterministic exact string)' do
      expect(renderer.call(packet: built_packet)).to eq('BD-4 saat ini tersedia.')
    end

    it 'renders the id unavailable template (deterministic exact string)' do
      expect(renderer.call(packet: built_packet(status: 'unavailable'))).to eq('Mohon maaf, BD-4 saat ini sedang habis.')
    end

    it 'renders the en available template (deterministic exact string)' do
      expect(renderer.call(packet: built_packet(language: 'en'))).to eq('BD-4 is currently in stock.')
    end

    it 'renders the en unavailable template (deterministic exact string)' do
      expect(renderer.call(packet: built_packet(language: 'en', status: 'unavailable'))).to eq("I'm sorry, BD-4 is currently out of stock.")
    end

    it 'names the authoritative/validated variant code' do
      expect(renderer.call(packet: built_packet)).to include('BD-4')
    end

    it 'adds NO quantity, warehouse/location, delivery/lead time, price, discount, or comparison claim' do
      %w[available unavailable].each do |status|
        text = renderer.call(packet: built_packet(status: status))

        expect(text).not_to match(/qty|jumlah|pcs|unit|gudang|warehouse|lokasi|location|kirim|delivery|pengiriman|lead.?time/i)
        expect(text).not_to match(/harga|price|rp|idr|diskon|discount|promo|promotion|dibanding|compared|biasanya/i)
        # No fabricated number anywhere beyond the digits inside the validated variant code (BD-4).
        expect(text.gsub('BD-4', '')).not_to match(/\d/)
        expect(text).not_to match(/\p{Sc}/)
      end
    end

    it 'does not surface the authoritative source / checked_at in the text' do
      text = renderer.call(packet: built_packet)

      expect(text).not_to match(/stock_repository|2026-09-30|checked_at|source/i)
    end
  end

  describe 'purity and safe repeated calls (no repository/formatter/provider/DB collaborator)' do
    it 'is deterministic across repeated calls and never mutates the input packet' do
      packet = stock_packet
      first = renderer.call(packet: packet)
      second = renderer.call(packet: packet)

      expect(first).to eq(second)
      expect(packet).to be_frozen
      expect(packet[:facts][:stock]).to eq(status: 'available', source: 'stock_repository', checked_at: '2026-09-30T12:00:00Z')
    end

    it 'constructs no repository / formatter / provider / authority collaborator' do
      # The packet is a pre-frozen fixture, so the ONLY code under observation is the renderer itself.
      packet = stock_packet
      expect(Marine::Catalog::StockRepository).not_to receive(:new)
      expect(Marine::Catalog::PriceDisplayFormatter).not_to receive(:new)
      expect(Marine::Llm::AssistantChatService).not_to receive(:new)

      expect(renderer.call(packet: packet)).to be_truthy
    end
  end

  # Gate map — each fail-closed structural gate returns nil (never repairs, never raises).
  describe 'fail closed (nil) — structural gate contract' do
    it '(1) returns nil when the packet is not a Hash' do
      [nil, 'x', 42, []].each { |packet| expect(renderer.call(packet: packet)).to be_nil }
    end

    it '(2) returns nil for a mutable (not deeply frozen) pseudo-packet called directly' do
      expect(renderer.call(packet: stock_packet(freeze: false))).to be_nil
    end

    it '(2) returns nil for a shallow-frozen packet (top-level Hash frozen, nested containers mutable)' do
      packet = stock_packet(freeze: false).freeze

      expect(packet).to be_frozen
      expect(packet[:facts]).not_to be_frozen

      expect(renderer.call(packet: packet)).to be_nil
    end

    it '(3) returns nil for a wrong evidence_version (v3 or bogus)' do
      expect(renderer.call(packet: deep_freeze(stock_packet(freeze: false).merge(evidence_version: 'marine_evidence_v3')))).to be_nil
      expect(renderer.call(packet: deep_freeze(stock_packet(freeze: false).merge(evidence_version: 'nope')))).to be_nil
    end

    it '(4) returns nil for a crossed packet that carries a presentation_policy (never on a v2 stock packet)' do
      policy = { tone: 'professional', verbosity: 'concise', range_followup_mode: 'standalone' }
      expect(renderer.call(packet: stock_packet(extra: { presentation_policy: policy }))).to be_nil
    end

    it '(5) returns nil for a non-stock or multi goal' do
      expect(renderer.call(packet: stock_packet(goals: %w[answer_price]))).to be_nil
      expect(renderer.call(packet: stock_packet(goals: %w[answer_stock answer_price]))).to be_nil
    end

    it '(6) returns nil when the scenario intents are not exactly stock' do
      expect(renderer.call(packet: stock_packet(scenario: { key: 'scenario_8', intents: %w[price] }))).to be_nil
      expect(renderer.call(packet: stock_packet(scenario: { key: 'scenario_8', intents: %w[stock price] }))).to be_nil
      expect(renderer.call(packet: stock_packet(scenario: 'nope'))).to be_nil
    end

    it '(7) returns nil for an unsupported / missing customer_language' do
      expect(renderer.call(packet: stock_packet(language: 'fr'))).to be_nil
      expect(renderer.call(packet: deep_freeze(stock_packet(freeze: false).tap { |p| p.delete(:customer_language) }))).to be_nil
    end

    it '(8) returns nil when the facts set is not exactly [:stock]' do
      expect(renderer.call(packet: stock_packet(facts: { stock: stock_fact, price: {} }))).to be_nil
      expect(renderer.call(packet: stock_packet(facts: {}))).to be_nil
      expect(renderer.call(packet: stock_packet(facts: { price: stock_fact }))).to be_nil
    end

    it '(9) returns nil when the stock fact keys are missing / extra' do
      expect(renderer.call(packet: stock_packet(facts: { stock: stock_fact.except(:checked_at) }))).to be_nil
      expect(renderer.call(packet: stock_packet(facts: { stock: stock_fact.merge(quantity: 10) }))).to be_nil
    end

    it '(10) returns nil for an unknown / blank / control-bearing status' do
      ['low', 'in_stock', '', 'avail able', "available\n"].each do |status|
        expect(renderer.call(packet: stock_packet(facts: { stock: stock_fact(status: status) }))).to be_nil
      end
    end

    it '(11) returns nil for a missing / wrong stock source' do
      expect(renderer.call(packet: stock_packet(facts: { stock: stock_fact(source: 'rag_cache') }))).to be_nil
      expect(renderer.call(packet: stock_packet(facts: { stock: stock_fact.except(:source) }))).to be_nil
    end

    it '(12) returns nil for a malformed / non-UTC / non-string checked_at' do
      ['30-09-2026', '2026-09-30T12:00:00+07:00', '2026-09-30 12:00:00', Time.utc(2026, 9, 30)].each do |checked_at|
        expect(renderer.call(packet: stock_packet(facts: { stock: stock_fact(checked_at: checked_at) }))).to be_nil
      end
    end

    it '(13) returns nil for an identity defect — absent variant slot, non-marine_catalog source, or blank/control code' do
      expect(renderer.call(packet: stock_packet(validated_slots: {}))).to be_nil
      expect(renderer.call(packet: stock_packet(validated_slots: { variant: { code: 'BD-4', attributes: {}, source: 'rag_cache' } }))).to be_nil
      expect(renderer.call(packet: stock_packet(validated_slots: { variant: { code: '  ', attributes: {}, source: 'marine_catalog' } }))).to be_nil
      expect(renderer.call(packet: stock_packet(validated_slots: { variant: { code: "BD\n4", attributes: {}, source: 'marine_catalog' } }))).to be_nil
      # A product-only slot (no resolved variant) cannot ground a binary stock identity.
      expect(renderer.call(packet: stock_packet(validated_slots: { product: { code: 'BD', attributes: {}, source: 'marine_catalog' } }))).to be_nil
    end
  end

  describe 'missing / blank locale translation fails closed (never an invented sentence)' do
    it 'returns nil when the available template is missing for the packet language' do
      allow(I18n).to receive(:t).and_call_original
      allow(I18n).to receive(:t).with('marine.catalog.stock.available', hash_including(locale: 'id')).and_return(nil)

      expect(renderer.call(packet: built_packet)).to be_nil
    end

    it 'returns nil when the unavailable template resolves to a blank string' do
      allow(I18n).to receive(:t).and_call_original
      allow(I18n).to receive(:t).with('marine.catalog.stock.unavailable', hash_including(locale: 'id')).and_return('   ')

      expect(renderer.call(packet: built_packet(status: 'unavailable'))).to be_nil
    end
  end
end
