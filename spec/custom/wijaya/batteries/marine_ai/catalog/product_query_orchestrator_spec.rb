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

    # Structural invariant (deterministic, independent of any prompt or LLM behavior): even when an
    # active flow already carries a validated family, a validated variant, and a product intent, a
    # turn the extractor classifies as non-product yields not_product with NO state operation. So the
    # runtime (Runner#product_payload returns nil for :not_product; the job never calls
    # apply_product_state for a :none op) emits no product/stock reply AND never mutates or resets the
    # validated context — a later genuine product follow-up still resumes it through the normal
    # continuation path. This is the deterministic guarantee that a non-substantive latest turn cannot
    # surface stale product intent, regardless of what the RAG generation later says in prose.
    it 'never surfaces or mutates stale product intent on a non-product turn over an active validated flow' do
      flow = active_flow('validated_family' => 'FAM-1', 'validated_variant' => 'CHILD-1', 'current_intent' => 'stock')
      plan = orchestrator.plan_for_intent(intent: intent(product_related: false, intent: 'unknown'), flow: flow)

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
      # Phase 3: a fresh unresolved family clarification opens a flow tracking occurrence 1.
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to include('clarification_kind' => 'family', 'clarification_count' => 1, 'current_intent' => 'price')
    end
  end

  describe 'price requires an exact validated child' do
    let(:price_intent) { intent(intent: 'price', explicit_child_code: 'CHILD-1', requires_exact_variant: true, family_mention: 'Impeller') }

    before { allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1') }

    it 'renders the deterministic available price (only the three approved fields)' do
      allow(price_repository).to receive(:price_for).with('CHILD-1').and_return(available_price)

      plan = orchestrator.plan_for_intent(intent: price_intent, flow: nil)

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply]).to eq(kind: :price_available, variant_code: 'CHILD-1', price_list_rate: '125.50', currency: 'USD', uom: 'Nos')
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
      expect(plan[:reply]).to eq(kind: :price_available, variant_code: 'CHILD-1', price_list_rate: '125.50', currency: 'USD', uom: 'Nos')
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
      # Phase 3: still a clarify (never a catalog) — opening occurrence 1 on a fresh flow.
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to include('clarification_kind' => 'family', 'clarification_count' => 1)
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

  # Phase 3 / D5 — structured clarification progression. Identity is the DURABLE unresolved slot
  # (kind + validated family + the bounded candidate-family-code set), NEVER the volatile per-turn
  # current_intent, raw text, or candidate values.
  describe 'family clarification progression' do
    before do
      allow(family_repository).to receive(:resolve_exact).and_return(nil)
      # Two families that do not uniquely recover, so the mention stays unresolved -> clarify.
      allow(family_repository).to receive(:active_candidates).and_return(
        [{ code: 'FAM-A', name: 'Alpha One' }, { code: 'FAM-B', name: 'Alpha Two' }]
      )
    end

    # A prior family-clarification flow persists the candidate-code SET the slot is blocked on
    # (matching the stubbed active_candidates above), so a later same-slot turn increments it.
    def family_clarify_flow(count, overrides = {})
      {
        'version' => 2, 'flow_id' => 'flow-1', 'status' => 'active', 'expires_at' => '2999-01-01T00:00:00Z',
        'expected_attributes' => [], 'current_intent' => 'price', 'clarification_kind' => 'family',
        'clarification_count' => count, 'clarification_family_codes' => %w[FAM-A FAM-B]
      }.merge(overrides)
    end

    it 'opens occurrence 1 on a fresh conversation (:start, count 1) and records the candidate-code set' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'price', family_mention: 'Zzz'), flow: nil)

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to include('clarification_kind' => 'family', 'clarification_count' => 1,
                                                'current_intent' => 'price', 'clarification_family_codes' => %w[FAM-A FAM-B])
    end

    it 'increments the SAME unresolved family state to occurrence 2 (:update, count 2)' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'price', family_mention: 'Zzz'), flow: family_clarify_flow(1))

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]).to include('clarification_kind' => 'family', 'clarification_count' => 2)
    end

    it 'hands off on the third occurrence of the same unresolved family state' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'price', family_mention: 'Zzz'), flow: family_clarify_flow(2))

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:clarify_family)
    end

    # D5 — the PROVEN defect: a valid terse/rephrased clarification the extractor relabels with a
    # different supported intent, over the SAME unresolved candidate family set, must keep
    # advancing (never reset), so the occurrence-3 handoff still fires.
    it 'increments the SAME unresolved family slot despite a current_intent label switch (occurrence 1 -> 2)' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'stock', family_mention: 'Zzz'), flow: family_clarify_flow(1))

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]).to include('clarification_count' => 2, 'current_intent' => 'stock')
    end

    it 'hands off on occurrence 3 of the same family slot even when the current_intent label switched' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'stock', family_mention: 'Zzz'), flow: family_clarify_flow(2))

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:clarify_family)
    end

    it 'is insensitive to candidate-family-code ORDER (same set, different order still increments)' do
      allow(family_repository).to receive(:active_candidates).and_return(
        [{ code: 'FAM-B', name: 'Alpha Two' }, { code: 'FAM-A', name: 'Alpha One' }]
      )

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'price', family_mention: 'Zzz'), flow: family_clarify_flow(1))

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:state][:changes]).to include('clarification_count' => 2)
    end

    it 'resets the progression to 1 when the candidate family SET genuinely changes (a different unresolved slot)' do
      allow(family_repository).to receive(:active_candidates).and_return(
        [{ code: 'FAM-C', name: 'Gamma' }, { code: 'FAM-D', name: 'Delta' }]
      )

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'price', family_mention: 'Zzz'), flow: family_clarify_flow(2))

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:state][:changes]).to include('clarification_count' => 1, 'clarification_family_codes' => %w[FAM-C FAM-D])
    end

    it 'preserves the validated family and catalog markers on an ambiguity over an active family (metadata-only update)' do
      allow(family_repository).to receive(:active_candidates).and_return(
        [{ code: 'FAM-1', name: 'Alpha' }, { code: 'FAM-2', name: 'Alpha' }]
      )
      flow = active_flow('validated_family' => 'FAM-1', 'catalog_sent' => true, 'catalog_document_id' => 77)

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'catalog', family_mention: 'Alpha'), flow: flow)

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]).to include('clarification_kind' => 'family', 'clarification_count' => 1)
      expect(plan[:state][:changes]).not_to have_key('validated_family')
      expect(plan[:state][:changes]).not_to have_key('catalog_sent')
    end

    it 'establishing the family from a prior family clarification is validated progress (resolved, metadata cleared)' do
      allow(family_repository).to receive(:resolve_exact).with('Impeller').and_return(code: 'FAM-1', name: 'Impeller')

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'parent_info', family_mention: 'Impeller'),
                                          flow: family_clarify_flow(2, 'current_intent' => 'parent_info'))

      expect(plan[:action]).to eq(:reply)
      expect(plan[:state][:operation]).to eq(:start) # switch to the newly validated family
      expect(plan[:state][:changes]).not_to have_key('clarification_count')
    end
  end

  describe 'clarification progression does not apply to non-clarification paths' do
    it 'never adds clarification metadata to an unsupported-intent handoff' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'unsupported'), flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:state]).to eq(operation: :none, changes: {})
    end

    it 'never adds clarification metadata to a repository-error handoff' do
      allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1')
      allow(stock_repository).to receive(:status_for).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'stock', explicit_child_code: 'CHILD-1', family_mention: 'Impeller'), flow: nil
      )

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:state]).to eq(operation: :none, changes: {})
    end

    it 'never adds clarification metadata to a price-conflict handoff' do
      allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1')
      allow(price_repository).to receive(:price_for).and_return(status: :conflict)

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'price', explicit_child_code: 'CHILD-1', requires_exact_variant: true, family_mention: 'Impeller'),
        flow: nil
      )

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:state][:changes]).not_to have_key('clarification_count')
    end

    it 'never enters progression on a nonproduct turn' do
      plan = orchestrator.plan_for_intent(intent: intent(product_related: false, intent: 'unknown'), flow: nil)

      expect(plan[:action]).to eq(:not_product)
      expect(plan[:state]).to eq(operation: :none, changes: {})
    end
  end

  describe 'variant clarification progression' do
    def variant_flow(count, overrides = {})
      active_flow('current_intent' => 'variant_info', 'validated_variant' => nil, 'expected_attributes' => %w[Size],
                  'clarification_kind' => 'variant', 'clarification_count' => count).merge(overrides)
    end

    def unresolved_variant_intent(overrides = {})
      intent(intent: 'variant_info', requires_exact_variant: true, explicit_child_code: 'CHILD-X', family_mention: 'Impeller').merge(overrides)
    end

    before { allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :ambiguous) }

    it 'clarifies occurrence 1 for an unresolved explicit candidate (:start, count 1)' do
      plan = orchestrator.plan_for_intent(intent: unresolved_variant_intent, flow: nil)

      expect(plan[:action]).to eq(:clarify_variant)
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to include('clarification_kind' => 'variant', 'clarification_count' => 1, 'expected_attributes' => %w[Size])
    end

    it 'increments to occurrence 2 on the SAME unresolved variant state (:update, count 2)' do
      plan = orchestrator.plan_for_intent(intent: unresolved_variant_intent, flow: variant_flow(1))

      expect(plan[:action]).to eq(:clarify_variant)
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]).to include('clarification_count' => 2)
    end

    it 'still increments (no progress) when only the candidate value changes without repository validation' do
      plan = orchestrator.plan_for_intent(intent: unresolved_variant_intent('explicit_child_code' => 'TOTALLY-DIFFERENT'),
                                          flow: variant_flow(1))

      expect(plan[:action]).to eq(:clarify_variant)
      expect(plan[:state][:changes]).to include('clarification_count' => 2)
    end

    # D5 — the same defect on the VARIANT slot: a relabelled supported intent (price -> stock) over
    # the SAME validated family + expected attributes is the SAME unresolved slot and must advance.
    it 'increments the SAME unresolved variant slot despite a current_intent label switch (occurrence 1 -> 2)' do
      plan = orchestrator.plan_for_intent(intent: unresolved_variant_intent(intent: 'stock'),
                                          flow: variant_flow(1, 'current_intent' => 'price'))

      expect(plan[:action]).to eq(:clarify_variant)
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]).to include('clarification_count' => 2)
    end

    it 'hands off on the third unresolved variant occurrence' do
      plan = orchestrator.plan_for_intent(intent: unresolved_variant_intent, flow: variant_flow(2))

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:clarify_variant)
    end

    it 'clears clarification metadata and executes the price behavior when a unique variant validates' do
      allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1')
      allow(price_repository).to receive(:price_for).with('CHILD-1').and_return(available_price)

      plan = orchestrator.plan_for_intent(
        intent: unresolved_variant_intent(intent: 'price'), flow: variant_flow(2, 'current_intent' => 'price')
      )

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply]).to eq(kind: :price_available, variant_code: 'CHILD-1', price_list_rate: '125.50', currency: 'USD', uom: 'Nos')
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]['clarification_kind']).to be_nil
      expect(plan[:state][:changes]['clarification_count']).to be_nil
    end
  end

  describe 'catalog-assisted variant clarification progression' do
    def variant_intent
      intent(intent: 'variant_info', requires_exact_variant: true, family_mention: 'Impeller')
    end

    it 'offers the native catalog on occurrence 1 (send_catalog, count 1)' do
      plan = orchestrator.plan_for_intent(intent: variant_intent, flow: nil)

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to be_nil
      expect(plan[:state][:changes]).to include('clarification_kind' => 'variant', 'clarification_count' => 1)
    end

    it 'clarifies without a second attachment on occurrence 2 once the catalog was sent (count 2)' do
      flow = active_flow('current_intent' => 'variant_info', 'validated_variant' => nil, 'catalog_sent' => true,
                         'expected_attributes' => %w[Size], 'clarification_kind' => 'variant', 'clarification_count' => 1)

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'variant_info', family_mention: nil), flow: flow)

      expect(plan[:action]).to eq(:clarify_variant)
      expect(plan[:state][:changes]).to include('clarification_count' => 2)
    end

    it 'hands off on occurrence 3 (never a second attachment)' do
      flow = active_flow('current_intent' => 'variant_info', 'validated_variant' => nil, 'catalog_sent' => true,
                         'expected_attributes' => %w[Size], 'clarification_kind' => 'variant', 'clarification_count' => 2)

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'variant_info', family_mention: nil), flow: flow)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:clarify_variant)
    end
  end

  # Phase 3 — a PATHOLOGICAL repository attribute list (>MAX items, duplicates, an overlong
  # item, a control character, and blanks) must canonicalize identically before the descriptor,
  # the progression identity, and the persisted state changes. Without one shared canonical
  # normalization, occurrence 1 (raw list) and its persisted-shaped occurrence 2 would compare
  # unequal, resetting the count to 1 forever instead of ever reaching a handoff.
  describe 'variant clarification progression survives a pathological repository attribute list' do
    let(:pathological) do
      %w[Size Size] + ['  Color  ', "Volt\u0000age", '', '   ', 'D' * 200] + Array.new(20) { |i| "Attr#{i}" }
    end
    let(:canonical) { Marine::Catalog::ProductFlowStateStore.normalize_expected_attributes(pathological) }

    def unresolved_variant_intent
      intent(intent: 'variant_info', requires_exact_variant: true, explicit_child_code: 'CHILD-X', family_mention: 'Impeller')
    end

    def pathological_variant_flow(count)
      active_flow('current_intent' => 'variant_info', 'validated_variant' => nil, 'expected_attributes' => canonical,
                  'clarification_kind' => 'variant', 'clarification_count' => count)
    end

    before do
      allow(variant_repository).to receive(:attribute_names).and_return(pathological)
      allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :ambiguous)
    end

    it 'is genuinely pathological: the raw list differs from its canonical (bounded) shape' do
      expect(canonical).not_to eq(pathological)
      expect(canonical.length).to eq(Marine::Catalog::ProductFlowStateStore::MAX_ATTRIBUTES)
    end

    it 'bounds the customer-facing descriptor and the persisted expected_attributes identically on occurrence 1' do
      plan = orchestrator.plan_for_intent(intent: unresolved_variant_intent, flow: nil)

      expect(plan[:action]).to eq(:clarify_variant)
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]['expected_attributes']).to eq(canonical)
      expect(plan[:reply][:attribute_names]).to eq(canonical)
      expect(plan[:state][:changes]).to include('clarification_count' => 1)
    end

    it 'matches the persisted-shaped occurrence 2 and increments the count (never resets to 1)' do
      plan = orchestrator.plan_for_intent(intent: unresolved_variant_intent, flow: pathological_variant_flow(1))

      expect(plan[:action]).to eq(:clarify_variant)
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]).to include('clarification_count' => 2)
    end

    it 'hands off on occurrence 3 rather than looping forever' do
      plan = orchestrator.plan_for_intent(intent: unresolved_variant_intent, flow: pathological_variant_flow(2))

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:clarify_variant)
    end
  end

  # Phase 3 — clarification identity compares the expected-attribute SET, not its order. A
  # repository that returns the SAME bounded/deduplicated attributes in a DIFFERENT order on a
  # later turn must still match the persisted occurrence and increment (never falsely reset to
  # occurrence 1); only a GENUINELY changed set resets.
  describe 'variant clarification progression is insensitive to expected-attribute order' do
    def unresolved_variant_intent
      intent(intent: 'variant_info', requires_exact_variant: true, explicit_child_code: 'CHILD-X', family_mention: 'Impeller')
    end

    def variant_flow(count, persisted_attributes)
      active_flow('current_intent' => 'variant_info', 'validated_variant' => nil, 'expected_attributes' => persisted_attributes,
                  'clarification_kind' => 'variant', 'clarification_count' => count)
    end

    before { allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :ambiguous) }

    it 'increments occurrence 1 -> 2 when the same set is returned in a different order' do
      allow(variant_repository).to receive(:attribute_names).and_return(%w[Color Size])

      plan = orchestrator.plan_for_intent(intent: unresolved_variant_intent, flow: variant_flow(1, %w[Size Color]))

      expect(plan[:action]).to eq(:clarify_variant)
      expect(plan[:state][:operation]).to eq(:update)
      expect(plan[:state][:changes]).to include('clarification_count' => 2)
    end

    it 'hands off on occurrence 3 for the same set surfaced in a different order' do
      allow(variant_repository).to receive(:attribute_names).and_return(%w[Color Size])

      plan = orchestrator.plan_for_intent(intent: unresolved_variant_intent, flow: variant_flow(2, %w[Size Color]))

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply][:kind]).to eq(:clarify_variant)
    end

    it 'resets to occurrence 1 when the canonical set genuinely changes' do
      allow(variant_repository).to receive(:attribute_names).and_return(%w[Color Material])

      plan = orchestrator.plan_for_intent(intent: unresolved_variant_intent, flow: variant_flow(1, %w[Size Color]))

      expect(plan[:action]).to eq(:clarify_variant)
      expect(plan[:state][:changes]).to include('clarification_count' => 1)
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
