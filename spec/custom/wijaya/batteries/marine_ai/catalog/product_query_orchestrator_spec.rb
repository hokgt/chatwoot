# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::ProductQueryOrchestrator do
  subject(:orchestrator) do
    described_class.new(
      repositories: { family: family_repository, variant: variant_repository, price: price_repository, stock: stock_repository },
      variant_resolver: variant_resolver
    )
  end

  let(:family_repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }
  let(:variant_repository) { instance_double(Marine::Catalog::VariantRepository) }
  let(:price_repository) { instance_double(Marine::Catalog::PriceRepository) }
  let(:stock_repository) { instance_double(Marine::Catalog::StockRepository) }
  let(:variant_resolver) { instance_double(Marine::Catalog::VariantResolver) }
  let(:available_price) { { status: :available, price_list_rate: '125.50', currency: 'USD', uom: 'Nos' } }

  before do
    allow(family_repository).to receive(:resolve_exact).and_return(code: 'FAM-1', name: 'Impeller')
    allow(family_repository).to receive(:active_candidates).and_return([])
    allow(variant_repository).to receive(:attribute_names).and_return(%w[Size])
    allow(variant_repository).to receive(:resolve_child).and_return(nil)
    allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :missing)
    allow(price_repository).to receive(:price_for).and_return(status: :unavailable)
    allow(stock_repository).to receive(:status_for).and_return(:empty)
  end

  # A full Phase-2-shaped (symbol-keyed) intent hash; overrides tailor each example.
  def intent(overrides = {})
    {
      product_related: true, intent: 'parent_info', family_mention: 'Impeller',
      explicit_child_code: nil, attribute_candidates: [], requires_exact_variant: false,
      clarification_reply: nil, family_changed: false, intent_changed: false,
      multiple_numeric_candidates: false, confidence: 'high', reason: 'extracted'
    }.merge(overrides)
  end

  # A Phase-3-shaped (string-keyed) active flow snapshot.
  def active_flow(overrides = {})
    {
      'version' => 2, 'flow_id' => 'flow-1', 'status' => 'active',
      'expires_at' => '2999-01-01T00:00:00Z', 'expected_attributes' => [],
      'validated_family' => 'FAM-1', 'current_intent' => 'variant_info'
    }.merge(overrides)
  end

  def deep_values(node)
    case node
    when Hash then node.flat_map { |k, v| [k, *deep_values(v)] }
    when Array then node.flat_map { |v| deep_values(v) }
    else [node]
    end
  end

  describe 'nonproduct' do
    it 'returns not_product for the general knowledge fallback, with no state change' do
      plan = orchestrator.plan_for_intent(intent: intent(product_related: false, intent: 'unknown'), flow: nil)

      expect(plan[:action]).to eq(:not_product)
      expect(plan[:reply]).to be_nil
      expect(plan[:state]).to eq(operation: :none, changes: {})
    end
  end

  describe 'unsupported product intent' do
    it 'hands off with a safe, factless descriptor' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'unsupported'), flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply]).to eq(kind: :unsupported)
    end

    it 'treats a product-related but unknown intent as unsupported' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'unknown'), flow: nil)

      expect(plan[:action]).to eq(:handoff)
    end
  end

  describe 'suppression (terminated / duplicate / stale)' do
    it 'stops with no output' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'price'), flow: nil, suppressed: true)

      expect(plan[:action]).to eq(:stop)
      expect(plan[:state]).to eq(operation: :none, changes: {})
    end
  end

  describe 'initial product query (parent-level)' do
    it 'validates the family via the repository and answers at parent level, starting a flow' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'parent_info', family_mention: 'Impeller'), flow: nil)

      expect(family_repository).to have_received(:resolve_exact).with('Impeller')
      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply]).to eq(kind: :parent_info, family_code: 'FAM-1', family_name: 'Impeller')
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to include('validated_family' => 'FAM-1', 'current_intent' => 'parent_info')
    end
  end

  describe 'family exact miss / ambiguous' do
    before { allow(family_repository).to receive(:resolve_exact).and_return(nil) }

    it 'returns a safe clarify_family with bounded candidates and never a catalog' do
      candidates = [{ code: 'FAM-1', name: 'Impeller A' }, { code: 'FAM-2', name: 'Impeller B' }]
      allow(family_repository).to receive(:active_candidates).and_return(candidates)

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'price', family_mention: 'Impeller'), flow: nil)

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:reply][:kind]).to eq(:clarify_family)
      expect(plan[:reply][:candidates].length).to eq(2)
      expect(plan[:state]).to eq(operation: :none, changes: {})
    end
  end

  describe 'price requires an exact validated child' do
    let(:price_intent) { intent(intent: 'price', explicit_child_code: 'CHILD-1', requires_exact_variant: true, family_mention: 'Impeller') }

    before { allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1') }

    it 'renders the deterministic available price (only the three approved fields)' do
      allow(price_repository).to receive(:price_for).with('CHILD-1').and_return(available_price)

      plan = orchestrator.plan_for_intent(intent: price_intent, flow: nil)

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply]).to eq(kind: :price_available, price_list_rate: '125.50', currency: 'USD', uom: 'Nos')
      expect(plan[:state][:changes]).to include('validated_variant' => 'CHILD-1', 'current_intent' => 'price')
    end

    it 'renders a deterministic unavailable reply when the price is missing' do
      allow(price_repository).to receive(:price_for).and_return(status: :unavailable)

      plan = orchestrator.plan_for_intent(intent: price_intent, flow: nil)

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply]).to eq(kind: :price_unavailable)
    end

    it 'fails closed to a handoff on a conflicting price' do
      allow(price_repository).to receive(:price_for).and_return(status: :conflict)

      plan = orchestrator.plan_for_intent(intent: price_intent, flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply]).to eq(kind: :price_conflict)
    end
  end

  describe 'stock requires an exact validated child' do
    let(:stock_intent) { intent(intent: 'stock', explicit_child_code: 'CHILD-1', family_mention: 'Impeller') }

    before { allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1') }

    it 'renders a binary available status with no raw quantity in the object graph' do
      allow(stock_repository).to receive(:status_for).with('CHILD-1').and_return(:available)

      plan = orchestrator.plan_for_intent(intent: stock_intent, flow: nil)

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply]).to eq(kind: :stock_available)
      expect(deep_values(plan)).to all(satisfy { |v| !v.is_a?(Numeric) })
    end

    it 'renders empty deterministically (empty is not unavailable)' do
      allow(stock_repository).to receive(:status_for).and_return(:empty)

      plan = orchestrator.plan_for_intent(intent: stock_intent, flow: nil)

      expect(plan[:reply]).to eq(kind: :stock_empty)
    end

    it 'fails closed to a handoff when the stock repository is unavailable (never a false empty)' do
      allow(stock_repository).to receive(:status_for).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)

      plan = orchestrator.plan_for_intent(intent: stock_intent, flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply]).to eq(kind: :catalog_unavailable)
    end

    it 'fails closed to a handoff on an unexpected status (never a false empty)' do
      allow(stock_repository).to receive(:status_for).and_return(:discontinued)

      plan = orchestrator.plan_for_intent(intent: stock_intent, flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply]).to eq(kind: :catalog_unavailable)
    end
  end

  describe 'context-dependent catalog need' do
    let(:variant_intent) { intent(intent: 'variant_info', requires_exact_variant: true, family_mention: 'Impeller') }

    it 'offers send_catalog only when nothing concrete was given and no catalog was sent' do
      plan = orchestrator.plan_for_intent(intent: variant_intent, flow: nil)

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to be_nil
      expect(plan[:state][:changes]).to include('expected_attributes' => %w[Size])
      expect(variant_resolver).not_to have_received(:resolve)
    end

    it 'never re-sends the catalog once marked sent — plain text clarify_variant instead' do
      flow = active_flow('current_intent' => 'variant_info', 'validated_variant' => nil, 'catalog_sent' => true)

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'variant_info', family_mention: nil), flow: flow)

      expect(plan[:action]).to eq(:clarify_variant)
      expect(plan[:reply][:kind]).to eq(:clarify_variant)
    end

    it 'clarifies (never first-picks or sends a catalog) on multiple numeric candidates' do
      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'variant_info', requires_exact_variant: true, multiple_numeric_candidates: true, family_mention: 'Impeller'),
        flow: nil
      )

      expect(plan[:action]).to eq(:clarify_variant)
    end

    it 'clarifies when a provided code/attribute fails to resolve uniquely (ambiguous)' do
      allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :ambiguous)

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'variant_info', explicit_child_code: 'CHILD-X', requires_exact_variant: true, family_mention: 'Impeller'),
        flow: nil
      )

      expect(plan[:action]).to eq(:clarify_variant)
    end
  end

  describe 'direct product catalog request' do
    def catalog_intent(overrides = {})
      intent(intent: 'catalog', requires_exact_variant: false).merge(overrides)
    end

    it 'validates the explicitly named family and sends the catalog directly, no variant required' do
      plan = orchestrator.plan_for_intent(intent: catalog_intent(family_mention: 'Impeller'), flow: nil)

      expect(family_repository).to have_received(:resolve_exact).with('Impeller')
      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-1', family_name: 'Impeller')
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to eq('validated_family' => 'FAM-1', 'current_intent' => 'catalog', 'expected_attributes' => [])
      expect(variant_resolver).not_to have_received(:resolve)
    end

    it 'reuses and revalidates the active flow family on a continuation with no repeated name' do
      flow = active_flow('current_intent' => 'catalog', 'validated_variant' => nil)

      plan = orchestrator.plan_for_intent(intent: catalog_intent(family_mention: nil), flow: flow)

      expect(family_repository).to have_received(:resolve_exact).with('FAM-1')
      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-1', family_name: 'Impeller')
      expect(plan[:state][:operation]).to eq(:update)
    end

    it 'clears stale variant context when a catalog continuation reuses a prior variant-required flow family' do
      flow = active_flow('current_intent' => 'price', 'validated_variant' => 'CHILD-1', 'expected_attributes' => %w[Size])

      plan = orchestrator.plan_for_intent(intent: catalog_intent(family_mention: nil), flow: flow)

      expect(family_repository).to have_received(:resolve_exact).with('FAM-1')
      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-1', family_name: 'Impeller')
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]).to include(
        'validated_family' => 'FAM-1', 'current_intent' => 'catalog',
        'validated_variant' => nil, 'expected_attributes' => []
      )
    end

    it 'starts a fresh flow for a catalog request that explicitly switches family' do
      flow = active_flow('validated_variant' => 'CHILD-1', 'catalog_sent' => true)
      allow(family_repository).to receive(:resolve_exact).with('Gasket').and_return(code: 'FAM-2', name: 'Gasket')

      plan = orchestrator.plan_for_intent(intent: catalog_intent(family_mention: 'Gasket', family_changed: true), flow: flow)

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-2', family_name: 'Gasket')
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).not_to have_key('validated_variant')
    end

    it 'clarifies (never sends a catalog) when the family is ambiguous / unresolved' do
      allow(family_repository).to receive(:resolve_exact).and_return(nil)

      plan = orchestrator.plan_for_intent(intent: catalog_intent(family_mention: 'Impeller'), flow: nil)

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:reply][:kind]).to eq(:clarify_family)
    end

    it 'clarifies when no family is named and no active flow family exists' do
      plan = orchestrator.plan_for_intent(intent: catalog_intent(family_mention: nil), flow: nil)

      expect(family_repository).not_to have_received(:resolve_exact)
      expect(plan[:action]).to eq(:clarify_family)
    end
  end

  describe 'variant resolved from repository only' do
    it 'answers variant_info from a unique attribute/value resolution' do
      allow(variant_resolver).to receive(:resolve)
        .with(family_code: 'FAM-1', explicit_child_code: nil, attribute_candidates: ['10'])
        .and_return(status: :resolved, code: 'CHILD-10')

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'variant_info', attribute_candidates: ['10'], requires_exact_variant: true, family_mention: 'Impeller'),
        flow: nil
      )

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply]).to eq(kind: :variant_info, family_code: 'FAM-1', variant_code: 'CHILD-10')
    end
  end

  describe 'code-only continuation while awaiting a variant' do
    it 'retains the flow (update op) and the family from the flow, resolving the given code' do
      flow = active_flow('current_intent' => 'price', 'validated_variant' => nil)
      allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1')
      allow(price_repository).to receive(:price_for).with('CHILD-1').and_return(available_price)

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'price', explicit_child_code: 'CHILD-1', family_mention: nil),
        flow: flow
      )

      expect(family_repository).to have_received(:resolve_exact).with('FAM-1')
      expect(plan[:action]).to eq(:reply)
      expect(plan[:state][:operation]).to eq(:update)
    end

    it 'retains the flow price intent when the bare code reply extracts as unknown' do
      flow = active_flow('current_intent' => 'price', 'validated_variant' => nil)
      allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1')
      allow(price_repository).to receive(:price_for).with('CHILD-1').and_return(available_price)

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'unknown', explicit_child_code: 'CHILD-1', family_mention: nil),
        flow: flow
      )

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply]).to eq(kind: :price_available, price_list_rate: '125.50', currency: 'USD', uom: 'Nos')
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]).to include('current_intent' => 'price', 'validated_variant' => 'CHILD-1')
    end

    it 'retains the flow stock intent when the bare code reply extracts as unsupported' do
      flow = active_flow('current_intent' => 'stock', 'validated_variant' => nil)
      allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1')
      allow(stock_repository).to receive(:status_for).with('CHILD-1').and_return(:available)

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'unsupported', explicit_child_code: 'CHILD-1', family_mention: nil),
        flow: flow
      )

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply]).to eq(kind: :stock_available)
      expect(plan[:state][:changes]).to include('current_intent' => 'stock')
    end

    it 'still hands off for an unsupported extraction with no code/attribute candidate' do
      flow = active_flow('current_intent' => 'price', 'validated_variant' => nil)

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'unsupported', explicit_child_code: nil, attribute_candidates: [], family_mention: nil),
        flow: flow
      )

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply]).to eq(kind: :unsupported)
    end
  end

  describe 'intent switch within the same family' do
    it 'updates current_intent and preserves a still-valid validated variant' do
      flow = active_flow('current_intent' => 'variant_info', 'validated_variant' => 'CHILD-1')
      allow(variant_repository).to receive(:resolve_child).with('FAM-1', 'CHILD-1').and_return(code: 'CHILD-1')
      allow(price_repository).to receive(:price_for).with('CHILD-1').and_return(available_price)

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'price', intent_changed: true, family_mention: nil),
        flow: flow
      )

      expect(plan[:action]).to eq(:reply)
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]).to include('current_intent' => 'price', 'validated_variant' => 'CHILD-1')
    end

    it 'closes variant clarification and clears the stale variant on a same-family parent switch' do
      flow = active_flow('current_intent' => 'variant_info', 'validated_variant' => 'CHILD-1', 'expected_attributes' => %w[Size])

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'parent_info', intent_changed: true, family_mention: nil),
        flow: flow
      )

      expect(plan[:action]).to eq(:reply)
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]).to include(
        'current_intent' => 'parent_info', 'validated_variant' => nil, 'expected_attributes' => []
      )
    end
  end

  describe 'family switch' do
    it 'requests a NEW flow (start) carrying only the new family — stale variant/catalog markers cleared' do
      flow = active_flow('validated_variant' => 'CHILD-1', 'catalog_sent' => true)
      allow(family_repository).to receive(:resolve_exact).with('Gasket').and_return(code: 'FAM-2', name: 'Gasket')

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'parent_info', family_mention: 'Gasket', family_changed: true),
        flow: flow
      )

      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to eq('validated_family' => 'FAM-2', 'current_intent' => 'parent_info', 'expected_attributes' => [])
      expect(plan[:state][:changes]).not_to have_key('validated_variant')
    end
  end

  describe 'data-driven family promotion for a partial mention' do
    # Exact match misses (partial mention); the bounded active-family search decides.
    before { allow(family_repository).to receive(:resolve_exact).and_return(nil) }

    it 'promotes a UNIQUE active family and plans send_catalog for a partial catalog mention' do
      allow(family_repository).to receive(:active_candidates)
        .with(query: 'Wid', limit: 2).and_return([{ code: 'FAM-9', name: 'Widget Deluxe' }])

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'catalog', family_mention: 'Wid'), flow: nil)

      expect(family_repository).to have_received(:resolve_exact).with('Wid')
      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-9', family_name: 'Widget Deluxe')
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to include('validated_family' => 'FAM-9', 'current_intent' => 'catalog')
    end

    it 'still clarifies (never a catalog) when SEVERAL active families match the partial mention' do
      candidates = [{ code: 'FAM-9', name: 'Widget Deluxe' }, { code: 'FAM-10', name: 'Widget Basic' }]
      allow(family_repository).to receive(:active_candidates).and_return(candidates)

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'catalog', family_mention: 'Widget'), flow: nil)

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:reply][:kind]).to eq(:clarify_family)
      expect(plan[:state]).to eq(operation: :none, changes: {})
    end

    it 'stays safe (clarify_family) when NO active family matches the partial mention' do
      allow(family_repository).to receive(:active_candidates).and_return([])

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'catalog', family_mention: 'Nope'), flow: nil)

      expect(plan[:action]).to eq(:clarify_family)
    end

    it 'switches from an active family to a uniquely matched new family without looping on clarification' do
      flow = active_flow('validated_family' => 'FAM-BASE', 'current_intent' => 'catalog', 'catalog_sent' => true)
      allow(family_repository).to receive(:active_candidates)
        .with(query: 'Gask', limit: 2).and_return([{ code: 'FAM-2', name: 'Gasket Ring' }])

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'catalog', family_mention: 'Gask', family_changed: true), flow: flow
      )

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-2', family_name: 'Gasket Ring')
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to include('validated_family' => 'FAM-2')
    end
  end

  describe 'no side effects and safe object graph' do
    it 'never instantiates a state store, provider, or writes state' do
      expect(Marine::Catalog::ProductFlowStateStore).not_to receive(:new)
      expect(Marine::Llm::BaseService).not_to receive(:new)

      orchestrator.plan_for_intent(intent: intent(intent: 'parent_info'), flow: nil)
    end

    it 'returns a deeply frozen plan whose action is always allowlisted' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'parent_info'), flow: nil)

      expect(plan).to be_frozen
      expect(plan[:reply]).to be_frozen
      expect(described_class::ACTIONS).to include(plan[:action])
      expect(described_class::STATE_OPERATIONS).to include(plan[:state][:operation])
    end
  end

  describe '#process (injected extractor, never the provider)' do
    subject(:orchestrator) do
      described_class.new(
        intent_extractor: extractor,
        repositories: { family: family_repository, variant: variant_repository, price: price_repository, stock: stock_repository },
        variant_resolver: variant_resolver
      )
    end

    let(:extractor) { instance_double(Marine::Catalog::IntentExtractor) }

    it 'extracts via the injected extractor with a safe state summary, then plans' do
      allow(extractor).to receive(:extract).and_return(intent(intent: 'parent_info', family_mention: 'Impeller'))

      plan = orchestrator.process(text: 'do you have impellers?', context: [], flow: nil)

      expect(extractor).to have_received(:extract)
        .with(hash_including(text: 'do you have impellers?', state: hash_including(:awaiting_code, :current_family, :current_intent)))
      expect(plan[:action]).to eq(:reply)
    end
  end
end
