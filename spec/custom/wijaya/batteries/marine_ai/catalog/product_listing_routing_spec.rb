# frozen_string_literal: true

require 'rails_helper'

# Regression specs for the fabric product-LISTING routing fix: a customer asking to
# ENUMERATE the products of a stated category (e.g. fabric — "kain apa saja?") must be
# answered from the DATABASE item table via the EXISTING listing authority
# (Marine::Catalog::ProductListingRepository#active_top_level — template rows only,
# has_variants = true), through the legacy conversational path
# (IntentExtractor -> ProductQueryOrchestrator#plan_for_intent -> ReplyRenderer/ReplyPresenter).
# A broad company-wide services overview STAYS on the product_overview -> :not_product
# RAG path, and price/stock/variant behavior is untouched. No example customer phrase is
# hardcoded anywhere in the production routing — routing is by the allowlisted
# 'product_listing' intent code only.
RSpec.describe 'Marine fabric product-listing routing', type: :model do
  let(:listing_repository) { Marine::Catalog::ProductListingRepository.new }
  let(:family_repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }
  let(:variant_repository) { instance_double(Marine::Catalog::VariantRepository) }
  let(:price_repository) { instance_double(Marine::Catalog::PriceRepository) }
  let(:price_range_repository) { instance_double(Marine::Catalog::PriceRangeRepository) }
  let(:stock_repository) { instance_double(Marine::Catalog::StockRepository) }
  let(:variant_resolver) { instance_double(Marine::Catalog::VariantResolver) }

  let(:orchestrator) do
    Marine::Catalog::ProductQueryOrchestrator.new(
      repositories: { family: family_repository, variant: variant_repository, price: price_repository,
                      price_range: price_range_repository, stock: stock_repository,
                      listing: Marine::Catalog::ProductListingRepository.new },
      variant_resolver: variant_resolver
    )
  end

  let(:presenter) { Marine::Catalog::ReplyPresenter.new }

  let(:listing_rows) do
    [{ 'code' => 'KAIN-01', 'name' => 'Katun' }, { 'code' => 'KAIN-02', 'name' => 'Denim' }]
  end
  let(:group_rows) { [{ 'item_group' => 'Kain' }] }
  let(:captured_sql) { [] }

  # Stub the low-level Connection (the same boundary the repository spec stubs) so the
  # REAL ProductListingRepository runs its template-only SQL and no live DB is touched.
  def stub_listing_connection!(rows: listing_rows, groups: group_rows, raise_error: false)
    allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
    allow(Marine::Catalog::Config).to receive(:qualified_table).and_return('marine_ai.item')
    allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
      captured_sql << { sql: sql, params: params }
      raise StandardError, 'catalog outage' if raise_error

      if sql.include?('COUNT(DISTINCT')
        [{ 'total' => 2 }]
      elsif sql.include?('MIN(BTRIM(item_group))')
        groups
      else
        rows
      end
    end
  end

  # A Phase-2-shaped (symbol-keyed) product-listing intent, as the extractor emits.
  def listing_intent(overrides = {})
    {
      product_related: true, intent: 'product_listing', family_mention: 'kain',
      explicit_child_code: nil, attribute_candidates: [], requires_exact_variant: false,
      clarification_reply: nil, family_changed: false, intent_changed: false,
      intent_scope: nil, multiple_numeric_candidates: false, quantity_inquiry: false,
      unsupported_request: nil, confidence: 'high', customer_language: 'id',
      requested_intents: [], reason: 'extracted'
    }.merge(overrides)
  end

  before do
    allow(family_repository).to receive(:resolve_exact).and_return(code: 'FAM-1', name: 'Impeller')
    allow(family_repository).to receive(:active_candidates).and_return([])
    allow(variant_repository).to receive(:attribute_names).and_return(%w[Size])
    allow(variant_repository).to receive(:resolve_child).and_return(nil)
    allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :missing)
    allow(price_repository).to receive(:price_for).and_return(status: :unavailable)
    allow(price_range_repository).to receive(:range_for).and_return(status: :unavailable)
    allow(stock_repository).to receive(:status_for).and_return(:empty)
  end

  describe 'IntentExtractor vocabulary' do
    subject(:extractor) { Marine::Catalog::IntentExtractor.new(base_service: base_service) }

    let(:base_service) { instance_double(Marine::Llm::BaseService, configured?: true) }
    let(:captured_prompts) { [] }

    def stub_llm(message:)
      allow(base_service).to receive(:complete) do |prompt:, system: nil, **options|
        captured_prompts << { prompt: prompt, system: system, options: options }
        { ok: true, message: message, error: nil }
      end
    end

    it 'allowlists product_listing as a transactional supported intent' do
      expect(Marine::Catalog::IntentExtractor::SUPPORTED_PRODUCT_INTENTS).to include('product_listing')
      expect(Marine::Catalog::IntentExtractor::ALLOWED_PRODUCT_INTENTS).to include('product_listing')
    end

    it 'normalizes an emitted product_listing intent unchanged with a single-element requested set' do
      stub_llm(message: %({"product_related": true, "intent": "product_listing", "family_mention": "kain"}))

      result = extractor.extract(text: 'Kain apa saja?')

      expect(result[:intent]).to eq('product_listing')
      expect(result[:family_mention]).to eq('kain')
      expect(result[:requested_intents]).to eq(%w[product_listing])
      expect(result[:reason]).to eq('extracted')
    end

    it 'documents the category-enumeration (product_listing) contract in the system prompt, distinct from product_overview' do
      stub_llm(message: %({"product_related": true, "intent": "product_listing"}))

      extractor.extract(text: 'Kain apa saja?')

      system = captured_prompts.last[:system]
      expect(system).to include('"product_listing"')
      # Generic semantic contract, stated before the broad overview examples: enumerate the
      # products of a stated category (dynamic names), vs the company-wide overview.
      expect(system.index('product_listing')).to be < system.index('What products does Textilindo sell?')
    end
  end

  describe 'orchestrator routing (plan_for_intent)' do
    it 'routes a product_listing turn to a DB listing reply, never not_product' do
      stub_listing_connection!

      plan = orchestrator.plan_for_intent(intent: listing_intent, flow: nil)

      expect(plan[:action]).to eq(:reply)
      expect(plan[:action]).not_to eq(:not_product)
      expect(plan[:reply][:kind]).to eq(:product_listing)
      expect(plan[:reply][:products]).to eq([{ code: 'KAIN-01', name: 'Katun' }, { code: 'KAIN-02', name: 'Denim' }])
      expect(plan[:reply][:item_group]).to eq('Kain')
    end

    it 'answers dynamically from the template-only item table (has_variants = true), scoped to the exact item group' do
      stub_listing_connection!

      orchestrator.plan_for_intent(intent: listing_intent, flow: nil)

      listing_call = captured_sql.find { |call| call[:sql].include?('DISTINCT ON (item_code)') }
      expect(listing_call).not_to be_nil
      expect(listing_call[:sql]).to include(Marine::Catalog::ProductListingRepository::TEMPLATE_LISTING_AUTHORITY_PREDICATE)
      expect(listing_call[:sql]).to include('has_variants = true')
      expect(listing_call[:params]).to include('Kain')
    end

    it 'falls back to the broad template listing when the extracted mention resolves to no item group' do
      stub_listing_connection!(groups: [])

      plan = orchestrator.plan_for_intent(intent: listing_intent(family_mention: 'unknown category'), flow: nil)

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply][:kind]).to eq(:product_listing)
      expect(plan[:reply][:item_group]).to be_nil
      listing_call = captured_sql.find { |call| call[:sql].include?('DISTINCT ON (item_code)') }
      expect(listing_call[:params]).to eq([21])
    end

    it 'hands off fail-closed on a catalog outage instead of fabricating a listing' do
      stub_listing_connection!(raise_error: true)

      plan = orchestrator.plan_for_intent(intent: listing_intent, flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:catalog_unavailable)
    end

    it 'keeps a broad company-wide services overview on the product_overview -> not_product RAG path' do
      stub_listing_connection!

      plan = orchestrator.plan_for_intent(intent: listing_intent(intent: 'product_overview', family_mention: nil), flow: nil)

      expect(plan[:action]).to eq(:not_product)
      expect(plan[:reply]).to be_nil
      expect(captured_sql).to be_empty
    end

    it 'keeps price, stock, and variant-required turns on their unchanged deterministic paths' do
      stub_listing_connection!

      # Unresolved variant on a price/stock turn keeps the existing catalog-assisted
      # price-range offer path (action :send_catalog) — untouched by the listing fix.
      price_plan = orchestrator.plan_for_intent(intent: listing_intent(intent: 'price'), flow: nil)
      expect(price_plan[:action]).to eq(:send_catalog)
      expect(price_plan[:reply][:kind]).to eq(:catalog_offer)

      stock_plan = orchestrator.plan_for_intent(intent: listing_intent(intent: 'stock'), flow: nil)
      expect(stock_plan[:action]).to eq(:send_catalog)

      expect(captured_sql).to be_empty # no listing read on the unchanged intents
    end
  end

  describe 'the full extractor -> orchestrator -> repository -> renderer seam (#process)' do
    let(:intent_extractor) { instance_double(Marine::Catalog::IntentExtractor) }

    let(:seam_orchestrator) do
      Marine::Catalog::ProductQueryOrchestrator.new(
        intent_extractor: intent_extractor,
        repositories: { listing: Marine::Catalog::ProductListingRepository.new }
      )
    end

    it 'plans the DB listing answer end-to-end for a fabric-enumeration turn' do
      stub_listing_connection!
      allow(intent_extractor).to receive(:extract).and_return(listing_intent)

      plan = seam_orchestrator.process(text: 'Kain apa saja?', context: nil, flow: nil)

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply][:kind]).to eq(:product_listing)
      expect(plan[:reply][:products].length).to eq(2)
      listing_call = captured_sql.find { |call| call[:sql].include?('DISTINCT ON (item_code)') }
      expect(listing_call[:sql]).to include('has_variants = true')
    end
  end

  describe 'ReplyPresenter deterministic listing text' do
    it 'renders the dynamic DB rows as one deterministic, fact-safe line' do
      stub_listing_connection!

      plan = orchestrator.plan_for_intent(intent: listing_intent, flow: nil)
      text = presenter.reply_text(plan)

      expect(text).to eq('Here are the Kain products we currently offer: Katun (KAIN-01), Denim (KAIN-02).')
    end

    it 'renders a truthful generic line for an empty listing, never a fabricated product' do
      stub_listing_connection!(rows: [])

      plan = orchestrator.plan_for_intent(intent: listing_intent(family_mention: nil), flow: nil)

      expect(plan[:reply][:products]).to eq([])
      expect(presenter.reply_text(plan)).to include('currently')
    end
  end
end
