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
  def stub_listing_connection!(rows: listing_rows, groups: group_rows, products: [], total: 2, raise_error: false)
    allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
    allow(Marine::Catalog::Config).to receive(:qualified_table).and_return('marine_ai.item')
    allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
      captured_sql << { sql: sql, params: params }
      raise StandardError, 'catalog outage' if raise_error

      if sql.include?('COUNT(DISTINCT')
        [{ 'total' => total }]
      elsif sql.include?('MIN(BTRIM(item_group))')
        groups
      elsif sql.include?('LOWER(BTRIM(item_code)) IN')
        products
      else
        rows
      end
    end
  end

  # A Phase-2-shaped (symbol-keyed) product-listing intent, as the extractor emits.
  def listing_intent(overrides = {})
    {
      product_related: true, intent: 'product_listing', family_mention: 'kain', listing_scope: 'item_group',
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
      stub_llm(message: %({"product_related": true, "intent": "product_listing", "family_mention": "kain", "listing_scope": "item_group"}))

      result = extractor.extract(text: 'Kain apa saja?')

      expect(result[:intent]).to eq('product_listing')
      expect(result[:family_mention]).to eq('kain')
      expect(result[:listing_scope]).to eq('item_group')
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

    it 'fails closed instead of broadening when an extracted nonblank scope resolves to no item group' do
      stub_listing_connection!(groups: [], products: [])

      plan = orchestrator.plan_for_intent(intent: listing_intent(family_mention: 'unknown category'), flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:unsupported)
      expect(captured_sql.none? { |call| call[:params] == [21] }).to be(true)
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
    it 'renders the dynamic DB rows as one deterministic, fact-safe line with the needs follow-up' do
      stub_listing_connection!

      plan = orchestrator.plan_for_intent(intent: listing_intent, flow: nil)
      text = presenter.reply_text(plan)

      expected = 'Here are the Kain products we currently offer: Katun, Denim.'
      expect(text).to eq("#{expected}#{Marine::Catalog::ReplyPresenter::PRODUCT_LISTING_NEEDS_QUESTION}")
    end

    it 'renders a truthful generic line for an empty listing, never a fabricated product' do
      stub_listing_connection!(rows: [])

      plan = orchestrator.plan_for_intent(
        intent: listing_intent(family_mention: nil, listing_scope: 'all_products'), flow: nil
      )

      expect(plan[:reply][:products]).to eq([])
      expect(presenter.reply_text(plan)).to include('currently')
    end
  end

  describe 'product_overview classification rescue (Layer 2 deterministic safety net)' do
    it 'routes a product_overview turn whose candidates resolve EXACTLY to one item group to the DB listing branch, never not_product' do
      stub_listing_connection!

      plan = orchestrator.plan_for_intent(intent: listing_intent(intent: 'product_overview', family_mention: 'kain'), flow: nil)

      expect(plan[:action]).to eq(:reply)
      expect(plan[:action]).not_to eq(:not_product)
      expect(plan[:reply][:kind]).to eq(:product_listing)
      expect(plan[:reply][:item_group]).to eq('Kain')
      expect(plan[:reply][:products]).to eq([{ code: 'KAIN-01', name: 'Katun' }, { code: 'KAIN-02', name: 'Denim' }])
    end

    it 'keeps a genuine company-level product_overview (no resolvable scope) on the unchanged not_product RAG path' do
      stub_listing_connection!

      plan = orchestrator.plan_for_intent(intent: listing_intent(intent: 'product_overview', family_mention: nil), flow: nil)

      expect(plan[:action]).to eq(:not_product)
      expect(plan[:reply]).to be_nil
      listing_call = captured_sql.find { |call| call[:sql].include?('DISTINCT ON (item_code)') }
      expect(listing_call).to be_nil
    end

    it 'keeps a product_overview turn with MISSING candidates (no item group match) on the not_product path' do
      stub_listing_connection!(groups: [])

      plan = orchestrator.plan_for_intent(intent: listing_intent(intent: 'product_overview', family_mention: 'unknown category'), flow: nil)

      expect(plan[:action]).to eq(:not_product)
      expect(plan[:reply]).to be_nil
    end

    it 'keeps a product_overview turn with AMBIGUOUS candidates (multiple item groups) on the not_product path' do
      stub_listing_connection!(groups: [{ 'item_group' => 'Kain' }, { 'item_group' => 'Katun Combed' }])

      plan = orchestrator.plan_for_intent(intent: listing_intent(intent: 'product_overview', family_mention: 'kain'), flow: nil)

      expect(plan[:action]).to eq(:not_product)
      expect(plan[:reply]).to be_nil
    end

    it 'routes a product_listing turn with greetings and polluted real conversational context to the DB listing reply' do
      stub_listing_connection!

      plan = orchestrator.plan_for_intent(
        intent: listing_intent(intent: 'product_listing', family_mention: 'kain'),
        flow: nil,
        text: 'halo kak, jadi untuk kain tadi ada apa aja ya'
      )

      expect(plan[:action]).to eq(:reply)
      expect(plan[:action]).not_to eq(:not_product)
      expect(plan[:reply][:kind]).to eq(:product_listing)
      expect(plan[:reply][:item_group]).to eq('Kain')
    end
  end

  describe 'IntentExtractor SYSTEM_PROMPT classification contract (Layer 1)' do
    subject(:extractor) { Marine::Catalog::IntentExtractor.new(base_service: base_service) }

    let(:base_service) { instance_double(Marine::Llm::BaseService, configured?: true) }
    let(:captured_prompts) { [] }

    before do
      allow(base_service).to receive(:complete) do |prompt:, system: nil, **options|
        captured_prompts << { prompt: prompt, system: system, options: options }
        { ok: true, message: %({"product_related": true, "intent": "product_listing"}), error: nil }
      end
    end

    it 'keeps the greetings/history-invariant category-enumeration contract markers in the system prompt' do
      extractor.extract(text: 'Kain apa saja?')

      system = captured_prompts.last[:system]
      # Both intents stay named in the JSON contract.
      expect(system).to include('"product_listing"')
      expect(system).to include('"product_overview"')
      # The category-enumeration semantics stay contract markers: a stated-category
      # enumeration is ALWAYS product_listing regardless of greetings or history.
      expect(system).to include('ALWAYS product_listing')
      expect(system).to include('regardless of greetings')
      expect(system).to include('NO single category or product type is in focus')
      # History-invariance: prior turns/assistant answers never reclassify the current turn.
      expect(system).to include('NEVER change the classification of')
      expect(system.index('product_listing')).to be < system.index('What products does Textilindo sell?')
    end
  end

  # WIJAYA_CUSTOM_START: listing-recommendation-routing
  describe 'P0 listing versus availability/recommendation routing' do
    it 'allowlists product_recommendation as informational and documents the generic three-way prompt contract' do
      expect(Marine::Catalog::IntentExtractor::ALLOWED_PRODUCT_INTENTS).to include('product_recommendation')
      expect(Marine::Catalog::IntentExtractor::SUPPORTED_PRODUCT_INTENTS).not_to include('product_recommendation')

      system = Marine::Catalog::IntentExtractor::SYSTEM_PROMPT
      expect(system).to include('named product')
      expect(system).to include('availability')
      expect(system).to include('product_recommendation')
      expect(system).to include('intended use')
      expect(system).to include('listing_scope')
      expect(system).to include('all_products')
      expect(system).to include('catalog_domain')
      expect(system).to include('CURRENT turn')
    end

    it 'defers a use-case recommendation to grounded knowledge only when approved knowledge is available' do
      expect(Marine::Catalog::Connection).not_to receive(:select)

      plan = orchestrator.plan_for_intent(
        intent: listing_intent(intent: 'product_recommendation', family_mention: 'worship garment'),
        flow: nil,
        knowledge_available: true
      )

      expect(plan[:action]).to eq(:not_product)
      expect(plan[:state]).to eq(operation: :none, changes: {})
    end

    it 'uses the existing factless handoff for a recommendation without approved knowledge' do
      expect(Marine::Catalog::Connection).not_to receive(:select)

      plan = orchestrator.plan_for_intent(
        intent: listing_intent(intent: 'product_recommendation', family_mention: 'worship garment'),
        flow: nil,
        knowledge_available: false
      )

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:unsupported)
      expect(plan[:state]).to eq(operation: :none, changes: {})
    end

    it 'does not let an active price or stock flow hijack a fresh recommendation turn' do
      expect(Marine::Catalog::Connection).not_to receive(:select)
      flow = {
        'status' => Marine::Catalog::ProductFlowStateStore::STATUS_ACTIVE,
        'validated_family' => 'LINEN-FLOW', 'validated_variant' => nil, 'current_intent' => 'stock'
      }

      plan = orchestrator.plan_for_intent(
        intent: listing_intent(intent: 'product_recommendation', family_mention: 'prayer garment',
                               intent_scope: 'new_intent'),
        flow: flow,
        knowledge_available: false
      )

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:unsupported)
      expect(plan[:state]).to eq(operation: :none, changes: {})
      expect(stock_repository).not_to have_received(:status_for)
    end

    it 'never broadens a nonblank listing scope that resolves to no item group' do
      stub_listing_connection!(groups: [], products: [])

      plan = orchestrator.plan_for_intent(
        intent: listing_intent(family_mention: 'missing category'),
        flow: nil
      )

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:unsupported)
      expect(captured_sql.none? { |call| call[:params] == [21] }).to be(true)
    end

    it 'defers an unresolved item-group listing to grounded knowledge when approved evidence exists' do
      stub_listing_connection!(groups: [], products: [])

      plan = orchestrator.plan_for_intent(
        intent: listing_intent(family_mention: 'intended use', listing_scope: 'item_group'),
        flow: nil,
        knowledge_available: true
      )

      expect(plan[:action]).to eq(:not_product)
      expect(captured_sql.none? { |call| call[:params] == [21] }).to be(true)
    end

    it 'fails closed when product_listing lacks a valid closed listing scope' do
      expect(Marine::Catalog::Connection).not_to receive(:select)

      plan = orchestrator.plan_for_intent(
        intent: listing_intent(listing_scope: nil),
        flow: nil
      )

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:unsupported)
    end

    it 'never broadens an ambiguous nonblank listing scope' do
      stub_listing_connection!(groups: [{ 'item_group' => 'A' }, { 'item_group' => 'B' }])

      plan = orchestrator.plan_for_intent(intent: listing_intent(family_mention: 'ambiguous scope'), flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(captured_sql.none? { |call| call[:params] == [21] }).to be(true)
    end

    it 'detects an exact top-level product candidate and never turns it into a broad listing' do
      stub_listing_connection!(groups: [], products: [{ 'code' => 'LINEN-FLOW', 'name' => 'Linen Flow' }])

      plan = orchestrator.plan_for_intent(intent: listing_intent(family_mention: 'Linen Flow'), flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(captured_sql.any? { |call| call[:sql].include?('LOWER(BTRIM(item_code)) IN') }).to be(true)
      expect(captured_sql.none? { |call| call[:params] == [21] }).to be(true)
    end

    it 'preserves a genuinely unscoped broad listing with truthful has_more and CTA wording' do
      rows = Array.new(21) { |index| { 'code' => format('TPL-%02d', index), 'name' => "Template #{index}" } }
      stub_listing_connection!(rows: rows, groups: [], total: 25)

      plan = orchestrator.plan_for_intent(
        intent: listing_intent(family_mention: 'kain', attribute_candidates: [], listing_scope: 'catalog_domain'),
        flow: nil
      )
      text = presenter.reply_text(plan)

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply]).to include(item_group: nil, complete: false, has_more: true)
      expect(plan[:reply][:products].length).to eq(20)
      expect(captured_sql.any? { |call| call[:params] == [21] }).to be(true)
      expect(captured_sql.any? { |call| call[:sql].include?('COUNT(DISTINCT') }).to be(true)
      expect(text).to include(Marine::Catalog::ReplyPresenter::PRODUCT_LISTING_MORE_SUFFIX)
      expect(text).to end_with(Marine::Catalog::ReplyPresenter::PRODUCT_LISTING_NEEDS_QUESTION)
    end
  end
  # WIJAYA_CUSTOM_END: listing-recommendation-routing
end
