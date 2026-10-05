# frozen_string_literal: true

require 'rails_helper'

# Phase 1 (Opsi B) — pure integration of the whole backend product pipeline:
# untrusted candidate plan -> CandidatePlanToProductIntentAdapter -> ProductExecutionPlanner
# (injected mocked repositories) -> EvidencePacketBuilder -> EvidencePacketPresenter (injected
# generator + semantic verifier). Execution authorization is backend-policy-owned (ExecutionPolicy),
# so the end-to-end path is PRICE-ONLY. No provider, ERP, catalog DB, or state is touched.
RSpec.describe 'Marine::Backend Fase 3A-1 pipeline', type: :model do
  let(:clock) { -> { Time.utc(2026, 9, 30, 12, 0, 0) } }

  let(:family_repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }
  let(:variant_resolver) { instance_double(Marine::Catalog::VariantResolver) }
  let(:price_repository) { instance_double(Marine::Catalog::PriceRepository) }
  let(:stock_repository) { instance_double(Marine::Catalog::StockRepository) }

  let(:adapter) { Marine::Backend::CandidatePlanToProductIntentAdapter.new }
  let(:planner) do
    Marine::Backend::ProductExecutionPlanner.new(
      family_repository: family_repository, variant_resolver: variant_resolver,
      price_repository: price_repository, stock_repository: stock_repository,
      price_formatter: Marine::Catalog::PriceDisplayFormatter.new, clock: clock
    )
  end
  let(:builder) { Marine::Backend::EvidencePacketBuilder.new(clock: clock) }
  let(:presenter) { Marine::Backend::EvidencePacketPresenter.new }

  let(:raw_plan) do
    {
      'schema_version' => 'marine_decision_v1',
      'scenario_candidate' => { 'key' => 'scenario_8', 'confidence' => 'high' },
      'intents' => %w[price],
      'slot_operations' => [
        { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'Santorini', 'candidate_type' => 'display_name' } },
        { 'operation' => 'set', 'slot' => 'variant_input', 'value' => { 'raw_candidate' => 'BD-4', 'candidate_type' => 'variant_code' } }
      ],
      'customer_language' => 'id', 'confidence' => 'high'
    }
  end

  before do
    allow(family_repository).to receive(:resolve_exact).with('Santorini').and_return(code: 'BD', name: 'Santorini')
    allow(variant_resolver).to receive(:resolve)
      .with(family_code: 'BD', explicit_child_code: 'BD-4', attribute_candidates: [])
      .and_return(status: :resolved, code: 'BD-4')
    allow(price_repository).to receive(:price_for).with('BD-4').and_return(status: :available, price_list_rate: '12500', currency: 'IDR', uom: 'Yard')
  end

  def build_packet
    plan = Marine::Decision::CandidatePlan.normalize(raw_plan)
    accepted = adapter.call(plan: plan, scenario_key: 'scenario_8')
    expect(accepted.ok?).to be(true)

    evidence_input = planner.call(product_intent: accepted.product_intent, intents: accepted.intents, scenario: accepted.scenario)
    builder.build(evidence_input: evidence_input)
  end

  it 'produces an exact-price packet end to end' do
    packet = build_packet
    expect(packet[:evidence_version]).to eq('marine_evidence_v2')
    expect(packet[:response_goals]).to contain_exactly('answer_price')
    expect(packet[:facts].keys).to contain_exactly(:price)
    expect(packet[:facts][:price][:display][:amount]).to eq('12.500')
    expect(packet[:scenario]).to eq(key: 'scenario_8', intents: %w[price])
    expect(packet[:validated_slots][:variant][:code]).to eq('BD-4')
  end

  it 'delivers a grounded generated reply when the verifier confirms' do
    result = presenter.call(packet: build_packet, generator: ->(**) { 'Untuk BD-4, harganya Rp 12.500 per yard.' },
                            customer_request: 'Harga BD-4?', fact_verifier: ->(**) { true })
    expect(result.ok?).to be(true)
    expect(result.text).to include('BD-4')
  end

  it 'requires the semantic verifier (fails closed without one)' do
    result = presenter.call(packet: build_packet, generator: ->(**) { 'Untuk BD-4, harganya Rp 12.500 per yard.' },
                            customer_request: 'x')
    expect(result).to have_attributes(ok: false, reason: :fact_unverified, fallback: :deterministic)
  end

  it 'falls back to deterministic (not handoff) when generation is rejected on the verified-fact packet' do
    result = presenter.call(packet: build_packet, generator: ->(**) { 'BD-4 harganya Rp 99.999 per yard.' },
                            customer_request: 'x', fact_verifier: ->(**) { true })
    expect(result).to have_attributes(ok: false, reason: :fact_rejected, fallback: :deterministic)
  end
end
