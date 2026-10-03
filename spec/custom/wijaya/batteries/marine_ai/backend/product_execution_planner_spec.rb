# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-1 (isolated / mock-only) — backend repository validation & execution plan. Every
# repository is INJECTED and mocked; no catalog DB, provider, or state is touched. The real
# PriceDisplayFormatter is used for the immutable display envelope (pure/deterministic).
RSpec.describe Marine::Backend::ProductExecutionPlanner do
  subject(:planner) do
    described_class.new(
      family_repository: family_repository, variant_resolver: variant_resolver,
      price_repository: price_repository, stock_repository: stock_repository,
      price_formatter: Marine::Catalog::PriceDisplayFormatter.new, clock: clock
    )
  end

  let(:clock) { -> { Time.utc(2026, 9, 30, 12, 0, 0) } }
  let(:catalog_error) { Marine::Catalog::Errors::CatalogUnavailableError }
  let(:checked_at) { '2026-09-30T12:00:00Z' }

  let(:family_repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }
  let(:variant_resolver) { instance_double(Marine::Catalog::VariantResolver) }
  let(:price_repository) { instance_double(Marine::Catalog::PriceRepository) }
  let(:stock_repository) { instance_double(Marine::Catalog::StockRepository) }

  def product_intent(overrides = {})
    {
      family_mention: 'Santorini', explicit_child_code: 'BD-4', attribute_candidates: [],
      customer_language: 'id'
    }.merge(overrides)
  end

  before do
    allow(family_repository).to receive(:resolve_exact).with('Santorini').and_return(code: 'BD', name: 'Santorini')
    allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'BD-4')
  end

  def call(intents:, capabilities:, intent_overrides: {})
    planner.call(product_intent: product_intent(intent_overrides), intents: intents,
                 scenario: { key: 'scenario_8', capabilities: capabilities })
  end

  describe 'execution boundary (defense in depth — never trusts the adapter)' do
    it 'hands off on an empty intent set' do
      result = call(intents: [], capabilities: %w[price])
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end

    it 'hands off on an unsupported intent even if the scenario lists it as a capability' do
      result = call(intents: %w[order_status], capabilities: %w[order_status price])
      expect(result[:response_goals]).to eq(%w[handoff])
    end

    it 'hands off when an intent is outside the scenario capabilities' do
      result = call(intents: %w[stock], capabilities: %w[price])
      expect(result[:response_goals]).to eq(%w[handoff])
    end
  end

  describe 'price' do
    before do
      allow(price_repository).to receive(:price_for).with('BD-4').and_return(status: :available, price_list_rate: '12500', currency: 'IDR',
                                                                             uom: 'Yard')
    end

    it 'produces the exact canonical + immutable display price fact' do
      result = call(intents: %w[price], capabilities: %w[price catalog])

      expect(result[:response_goals]).to eq(%w[answer_price])
      expect(result[:facts][:price]).to eq(
        canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' },
        display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' },
        policy_version: 'price-display-v1', source: 'catalog_price_repository', checked_at: checked_at
      )
      expect(result[:validated_slots][:variant][:code]).to eq('BD-4')
    end

    it 'hands off (no price fact) when the price is unavailable' do
      allow(price_repository).to receive(:price_for).with('BD-4').and_return(status: :unavailable)
      result = call(intents: %w[price], capabilities: %w[price catalog])

      expect(result[:facts]).not_to have_key(:price)
      expect(result[:response_goals]).to include('handoff')
    end
  end

  describe 'stock' do
    it 'maps available -> available' do
      allow(stock_repository).to receive(:status_for).with('BD-4').and_return(:available)
      result = call(intents: %w[stock], capabilities: %w[stock])
      expect(result[:facts][:stock]).to eq(status: 'available', source: 'stock_repository', checked_at: checked_at)
    end

    it 'maps empty -> unavailable' do
      allow(stock_repository).to receive(:status_for).with('BD-4').and_return(:empty)
      result = call(intents: %w[stock], capabilities: %w[stock])
      expect(result[:facts][:stock][:status]).to eq('unavailable')
    end

    it 'OMITS the stock fact and hands off on a repository outage (never unknown/quantity)' do
      allow(stock_repository).to receive(:status_for).with('BD-4').and_raise(catalog_error)
      result = call(intents: %w[stock], capabilities: %w[stock])

      expect(result[:facts]).not_to have_key(:stock)
      expect(result[:response_goals]).to include('handoff')
    end
  end

  describe 'exact-code-only variant authority (3A-1)' do
    it 'passes NO attribute candidates to the resolver even when the input carries them' do
      expect(variant_resolver).to receive(:resolve)
        .with(family_code: 'BD', explicit_child_code: 'BD-4', attribute_candidates: [])
        .and_return(status: :resolved, code: 'BD-4')
      allow(price_repository).to receive(:price_for).with('BD-4').and_return(status: :available, price_list_rate: '12500', currency: 'IDR',
                                                                             uom: 'Yard')

      call(intents: %w[price], capabilities: %w[price], intent_overrides: { attribute_candidates: %w[Blue] })
    end

    it 'clarifies (never resolves) when only an attribute candidate is present and no exact code' do
      allow(variant_resolver).to receive(:resolve)
        .with(family_code: 'BD', explicit_child_code: nil, attribute_candidates: [])
        .and_return(status: :unresolved, reason: :missing)
      result = call(intents: %w[price], capabilities: %w[price],
                    intent_overrides: { explicit_child_code: nil, attribute_candidates: %w[Blue] })

      expect(result[:response_goals]).to eq(%w[clarify_variant])
    end
  end

  describe 'combined price+stock (one compatible scenario)' do
    it 'produces two verified fact blocks with independent checked_at' do
      allow(price_repository).to receive(:price_for).with('BD-4').and_return(status: :available, price_list_rate: '12500', currency: 'IDR',
                                                                             uom: 'Yard')
      allow(stock_repository).to receive(:status_for).with('BD-4').and_return(:available)

      result = call(intents: %w[price stock], capabilities: %w[price stock catalog product_overview parent_info])

      expect(result[:response_goals]).to contain_exactly('answer_price', 'answer_stock')
      expect(result[:facts].keys).to contain_exactly(:price, :stock)
      expect(result[:facts][:price][:checked_at]).to eq(checked_at)
      expect(result[:facts][:stock][:checked_at]).to eq(checked_at)
    end
  end

  describe 'unresolved / ambiguous slots (never guessed)' do
    it 'clarifies the product when no exact family matches' do
      allow(family_repository).to receive(:resolve_exact).with('Ghost').and_return(nil)
      result = call(intents: %w[price], capabilities: %w[price], intent_overrides: { family_mention: 'Ghost' })

      expect(result[:response_goals]).to eq(%w[clarify_product])
      expect(result[:missing_slots]).to eq(%w[product])
      expect(result[:facts]).to eq({})
    end

    it 'clarifies an ambiguous variant' do
      allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :ambiguous)
      result = call(intents: %w[price], capabilities: %w[price])

      expect(result[:response_goals]).to eq(%w[clarify_ambiguous_variant])
      expect(result[:missing_slots]).to eq(%w[variant_input])
    end

    it 'clarifies a missing variant' do
      allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :missing)
      result = call(intents: %w[price], capabilities: %w[price])
      expect(result[:response_goals]).to eq(%w[clarify_variant])
    end
  end

  describe 'defense in depth on a direct call' do
    it 'hands off (never raises) when product_intent is not a Hash' do
      result = planner.call(product_intent: nil, intents: %w[price], scenario: { key: 'scenario_8', capabilities: %w[price] })
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end
  end

  describe 'catalog outage' do
    it 'hands off on a family repository outage' do
      allow(family_repository).to receive(:resolve_exact).with('Santorini').and_raise(catalog_error)
      result = call(intents: %w[price], capabilities: %w[price])
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end
  end

  describe 'informational product_overview' do
    it 'answers product overview WITH a validated family (over its product slot)' do
      result = planner.call(product_intent: product_intent(family_mention: 'Santorini', explicit_child_code: nil),
                            intents: %w[product_overview], scenario: { key: 'scenario_8', capabilities: %w[product_overview] })
      expect(result[:response_goals]).to eq(%w[answer_product_overview])
      expect(result[:validated_slots][:product][:code]).to eq('BD')
      expect(result[:facts]).to eq({})
    end

    it 'hands off (never answers over an empty slot/fact packet) with NO family evidence' do
      result = planner.call(product_intent: product_intent(family_mention: nil, explicit_child_code: nil),
                            intents: %w[product_overview], scenario: { key: 'scenario_8', capabilities: %w[product_overview] })
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:validated_slots]).to eq({})
      expect(result[:facts]).to eq({})
    end
  end

  it 'returns a deeply frozen evidence input' do
    allow(price_repository).to receive(:price_for).and_return(status: :available, price_list_rate: '12500', currency: 'IDR', uom: 'Yard')
    result = call(intents: %w[price], capabilities: %w[price])
    expect(result).to be_frozen
    expect(result[:facts][:price]).to be_frozen
  end
end
