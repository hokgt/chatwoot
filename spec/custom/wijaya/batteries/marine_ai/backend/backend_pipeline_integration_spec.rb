# frozen_string_literal: true

require 'rails_helper'

# Phase 6 — unified customer orchestration proof.
#
# Every already-accepted Marine customer capability (product_listing, exact price, binary stock,
# family price_range, and product_information) is driven through the ONE generalized customer seam the
# runtime uses — Marine::Backend::ExactPriceCustomerExecution — composing the REAL
# CandidatePlanToProductIntentAdapter + ExecutionPolicy, AuthorityCoordinator, ProductExecutionPlanner,
# EvidencePacketBuilder, and EvidencePacketPresenter/PostGenerationFactValidator/PersonaValidator. Only
# deterministic synthetic doubles stand in for the Catalog repositories, the family price-range
# authority, the RAG description source, the Decision provider output (ONE CandidatePlan per turn), the
# Model 2 generated candidate, and the semantic verdict. No live provider, catalog DB, or RAG network is
# touched; the previous price-only pure-pipeline proof is subsumed by this seam-level matrix.
#
# Collaborators live in instance variables (not memoized helpers) so the composition is built once in a
# single `before` and the whole real adapter→coordinator→planner→builder→presenter chain is exercised.
RSpec.describe 'Marine::Backend Phase 6 unified customer orchestration', type: :model do
  before do
    @captured = {}
    clock = -> { Time.utc(2026, 9, 30, 12, 0, 0) }

    # --- Customer-turn records (minimal relationship doubles, as in the exact-price seam spec) --------
    @account = double('account', id: 7)
    @assistant = double('assistant', id: 8, account_id: 7)
    inbox = double('inbox', marine_assistant: @assistant)
    @conversation = double('conversation', id: 9, account_id: 7, inbox: inbox)
    @message = double('message', conversation_id: 9, incoming?: true, private?: false)
    context = Struct.new(:trigger, :history).new('synthetic customer request', [])
    @context_builder = double('context_builder', build: context)
    @scenario_adapter = double('scenario_adapter', overflow?: false, scenarios: [{ 'key' => 'scenario_8' }])
    @decision_runner = double('decision_runner')

    # --- Deterministic synthetic collaborators (the ONLY doubles) -----------------------------------
    @family_repository = instance_double(Marine::Catalog::ProductFamilyRepository)
    @variant_resolver = instance_double(Marine::Catalog::VariantResolver)
    @price_repository = instance_double(Marine::Catalog::PriceRepository)
    @stock_repository = instance_double(Marine::Catalog::StockRepository)
    @listing_repository = instance_double(Marine::Catalog::ProductListingRepository)
    @range_authority = instance_double(Marine::Backend::FamilyPriceRangeAuthority)
    @catalog_resolver = instance_double(Marine::Backend::CatalogCandidateResolver)
    @listing_scope_resolver = instance_double(Marine::Backend::ListingScopeResolver)
    @description_source = double('rag_description_source')
    language_resolver = class_double(Marine::Catalog::ConversationLanguageResolver)
    allow(language_resolver).to receive(:resolve).and_return(double('lang', language: 'id'))

    # The REAL planner over the synthetic repositories; the REAL packet builder; the REAL coordinator
    # composing the REAL adapter (backend ExecutionPolicy authorization) with the injected resolver.
    planner = Marine::Backend::ProductExecutionPlanner.new(
      family_repository: @family_repository, variant_resolver: @variant_resolver,
      price_repository: @price_repository, stock_repository: @stock_repository,
      listing_repository: @listing_repository, range_authority: @range_authority,
      description_source: @description_source, price_formatter: Marine::Catalog::PriceDisplayFormatter.new,
      clock: clock
    )
    @coordinator = Marine::Backend::AuthorityCoordinator.new(
      resolver: @catalog_resolver, listing_scope_resolver: @listing_scope_resolver,
      planner: planner, packet_builder: Marine::Backend::EvidencePacketBuilder.new(clock: clock),
      range_authority: @range_authority, language_resolver: language_resolver
    )

    stub_identity_catalog
    stub_listing_catalog
    stub_model_collaborators
  end

  # The existing authority composition the runtime uses: the generalized customer seam forwards the EXACT
  # CandidatePlan object to the Backend Authority. This thin wrapper drives the REAL coordinator (closing
  # the §7.5 signature the shadow execution would otherwise supply) and records the forwarded object so
  # the single-plan contract can be asserted.
  def authority_execution
    coord = @coordinator
    cap = @captured
    Object.new.tap do |obj|
      obj.define_singleton_method(:call) do |candidate_plan:, presentation_policy: nil|
        cap[:forwarded_plan] = candidate_plan
        cap[:forwarded_policy] = presentation_policy
        coord.call(candidate_plan: candidate_plan, scenario_key: 'scenario_8', trigger: 'synthetic trigger',
                   history: [], phase: :follow_up, flow_state: nil, configured_language: 'id',
                   presentation_policy: presentation_policy)
      end
    end
  end

  # Model 2 generated candidate + semantic verdict, injected as the ONLY model collaborators. They record
  # exactly which keyword arguments they receive so the "packet + bounded context only, never repository
  # handles" isolation is provable. The generated text is set per example via @model2 and the semantic
  # verdict via @verdict (default accept).
  def stub_model_collaborators
    @generator = double('model2_generator')
    @fact_verifier = double('semantic_verifier')
    allow(@generator).to receive(:call) do |**kwargs|
      @captured[:generator_args] = kwargs.keys
      @model2
    end
    allow(@fact_verifier).to receive(:call) do |**kwargs|
      @captured[:verifier_args] = kwargs.keys
      @captured[:packet] = kwargs[:packet]
      @captured[:candidate] = kwargs[:candidate]
      @verdict.nil? || @verdict
    end
  end

  # Exact-identity catalog authority (price / stock / price_range) — the resolver grounds identity and
  # the planner repositories own every fact.
  def stub_identity_catalog
    allow(@family_repository).to receive(:resolve_exact).with('BD').and_return(code: 'BD', name: 'Santorini')
    allow(@variant_resolver).to receive(:resolve)
      .with(family_code: 'BD', explicit_child_code: 'BD-4', attribute_candidates: [])
      .and_return(status: :resolved, code: 'BD-4')
    allow(@price_repository).to receive(:price_for)
      .with('BD-4')
      .and_return(status: :available, price_list_rate: '12500', currency: 'IDR', uom: 'Yard')
    allow(@stock_repository).to receive(:status_for).with('BD-4').and_return(:available)
    stub_range_authority
  end

  def stub_range_authority
    allow(@range_authority).to receive(:call).with(family_code: 'BD').and_return(
      Marine::Backend::FamilyPriceRangeAuthority::Result.new(
        status: :available, min: '10000', max: '45000', currency: 'IDR', uom: 'Yard',
        source: 'catalog_price_range_repository', checked_at: '2026-09-30T12:00:00Z'
      ).freeze
    )
  end

  def stub_listing_catalog
    # Catalog-wide listing authority: a bounded, incomplete top-level page (2 of 9) of code+name rows.
    allow(@listing_repository).to receive(:active_top_level).and_return(
      products: [{ code: 'BD', name: 'Santorini' }, { code: 'AMZ', name: 'Amazon' }],
      returned_count: 2, total_count: 9, complete: false, has_more: true
    )
    allow(@listing_repository).to receive(:exact_top_level)

    # Approved RAG source: it offers a description for the listed BD AND an OFF-PAGE code (ZZZ). The
    # planner may annotate only a listed code, so ZZZ can never be added/renamed into the catalog set.
    allow(@description_source).to receive(:call).and_return(
      'BD' => 'A premium marine fabric.', 'ZZZ' => 'Off-page item that must never appear.'
    )
    allow(@catalog_resolver).to receive(:call)
    allow(@listing_scope_resolver).to receive(:call).and_return(
      Marine::Backend::ListingScopeResolver::Result.new(status: :broad, product: nil, item_group: nil).freeze
    )
  end

  # --- Helpers -------------------------------------------------------------------------------------

  def execution
    Marine::Backend::ExactPriceCustomerExecution.new(
      account: @account, assistant: @assistant, conversation: @conversation, message: @message,
      decision_runner: @decision_runner, scenario_adapter: @scenario_adapter,
      authority_execution: authority_execution, generator: @generator,
      fact_verifier: @fact_verifier, context_builder: @context_builder
    )
  end

  def product_op(candidate)
    { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => candidate, 'candidate_type' => 'display_name' } }
  end

  def normalized_plan(intents:, ops: [])
    Marine::Decision::CandidatePlan.normalize(
      'schema_version' => 'marine_decision_v1',
      'scenario_candidate' => { 'key' => 'scenario_8', 'confidence' => 'high' },
      'intents' => intents, 'slot_operations' => ops,
      'customer_language' => 'id', 'confidence' => 'high'
    )
  end

  def stub_decision(plan)
    @plan = plan
    allow(@decision_runner).to receive(:call).and_return(plan)
  end

  def resolver_result(status:, child_code: nil, family_code: 'BD', family_name: 'Santorini', source: :current_turn, reason: :accepted) # rubocop:disable Metrics/ParameterLists -- a flat resolver-Result builder for the examples
    Marine::Backend::CatalogCandidateResolver::Result.new(
      status: status, source: source, family_code: family_code,
      family_name: family_name, child_code: child_code, reason: reason
    ).freeze
  end

  # ================================================================================================
  # 1. The accepted-capability matrix: each capability traverses the SAME seam to a valid reply.
  # ================================================================================================
  describe 'every accepted capability reaches a valid customer reply through the one seam' do
    it 'exact price: the PriceRepository authority reaches a fact-guarded reply' do
      allow(@catalog_resolver).to receive(:call).and_return(resolver_result(status: :exact_child, child_code: 'BD-4'))
      stub_decision(normalized_plan(intents: %w[price], ops: [product_op('JEV-GUESS')]))
      @model2 = 'Harga Santorini BD varian BD-4 adalah Rp 12.500 per yard.'

      result = execution.call

      expect(result).to be_deliverable
      expect(result.text).to eq(@model2)
      expect(@captured[:packet][:response_goals]).to eq(%w[answer_price])
      expect(@captured[:packet][:facts].keys).to eq(%i[price])
      # Only price_range adopts v3: the exact-price packet stays v2 and carries NO presentation_policy.
      expect(@captured[:packet][:evidence_version]).to eq('marine_evidence_v2')
      expect(@captured[:packet]).not_to have_key(:presentation_policy)
      # The authoritative identity came from the catalog repository, never the untrusted JEV candidate.
      expect(@captured[:packet][:validated_slots][:product][:code]).to eq('BD')
      expect(@captured[:packet][:facts][:price][:display][:amount]).to eq('12.500')
      expect(@family_repository).not_to have_received(:resolve_exact).with('JEV-GUESS')
      expect(@stock_repository).not_to have_received(:status_for)
      expect(@description_source).not_to have_received(:call)
    end

    it 'product_listing: Catalog-authorized code/name reaches a reply (no identity resolver, no RAG)' do
      stub_decision(normalized_plan(intents: %w[product_listing]))
      @model2 = 'Berikut 2 dari 9 produk kami: BD (Santorini) dan AMZ (Amazon).'

      result = execution.call

      expect(result).to be_deliverable
      expect(result.text).to eq(@model2)
      expect(@captured[:packet][:response_goals]).to eq(%w[answer_product_listing])
      expect(@captured[:packet][:facts].keys).to eq(%i[product_listing])
      listing = @captured[:packet][:facts][:product_listing]
      expect(listing[:products].map { |p| p[:code] }).to eq(%w[BD AMZ])
      expect(listing[:products].map { |p| p.key?(:description) }).to all(be(false))
      expect(listing).to include(returned_count: 2, total_count: 9, complete: false)
      expect(@catalog_resolver).not_to have_received(:call)
      expect(@description_source).not_to have_received(:call)
    end

    it 'product_information: identity/set from Catalog, description only from RAG for a listed code' do
      stub_decision(normalized_plan(intents: %w[product_information]))
      @model2 = 'Berikut 1 dari 9 produk: BD (Santorini) — A premium marine fabric.'

      result = execution.call

      expect(result).to be_deliverable
      expect(result.text).to eq(@model2)
      expect(@captured[:packet][:response_goals]).to eq(%w[answer_product_information])
      expect(@captured[:packet][:facts].keys).to eq(%i[product_listing])
      products = @captured[:packet][:facts][:product_listing][:products]
      # RAG may ONLY annotate an already-listed code: BD is described and kept; the undescribed AMZ is
      # dropped and the off-page ZZZ is never added or renamed in.
      expect(products.map { |p| p[:code] }).to eq(%w[BD])
      expect(products.first[:description]).to eq('A premium marine fabric.')
      expect(result.text).not_to include('ZZZ')
      expect(result.text).not_to include('AMZ')
      expect(@description_source).to have_received(:call).once
      expect(@catalog_resolver).not_to have_received(:call)
      expect(result.transition).to be_nil
    end

    it 'product_information: an exact repository-authorized family carries a packet-bound clean-switch transition' do
      allow(@listing_scope_resolver).to receive(:call).and_return(
        Marine::Backend::ListingScopeResolver::Result.new(
          status: :product, product: { code: 'BD', name: 'Baby Doll' }.freeze, item_group: nil
        ).freeze
      )
      allow(@listing_repository).to receive(:exact_top_level).with('BD').and_return(code: 'BD', name: 'Baby Doll')
      stub_decision(normalized_plan(intents: %w[product_information], ops: [product_op('Baby Doll')]))
      @model2 = 'BD (Baby Doll): A premium marine fabric.'

      result = execution.call

      expect(result).to be_deliverable
      expect(@captured[:packet].dig(:validated_slots, :product)).to include(code: 'BD', source: 'marine_catalog')
      expect(@captured[:packet].dig(:facts, :product_listing, :products).map { |product| product[:code] }).to eq(%w[BD])
      expect(result.transition).to eq(
        schema_version: 'state_transition_v1', operation: :start, capability: 'family_context',
        handoff_required: false,
        authoritative_identity: { family_code: 'BD', source: 'marine_catalog' }
      )
      expect(result.transition).to be_frozen
      expect(result.transition[:authoritative_identity]).to be_frozen
    end

    it 'price_range: FamilyPriceRangeAuthority values and provenance reach a reply (family-level, no variant)' do
      allow(@catalog_resolver).to receive(:call).and_return(resolver_result(status: :exact_family))
      stub_decision(normalized_plan(intents: %w[price_range]))
      @model2 = 'Kisaran harga Santorini BD berada di antara Rp 10.000 hingga Rp 45.000 per yard.'

      result = execution.call

      expect(result).to be_deliverable
      expect(result.text).to eq(@model2)
      expect(@captured[:packet][:response_goals]).to eq(%w[answer_price_range])
      expect(@captured[:packet][:facts].keys).to eq(%i[price_range])
      range = @captured[:packet][:facts][:price_range]
      expect(range[:canonical]).to include(family_code: 'BD', min: '10000', max: '45000')
      expect(range[:display]).to include(min: '10.000', max: '45.000')
      expect(range[:source]).to eq('catalog_price_range_repository')
      expect(@range_authority).to have_received(:call).with(family_code: 'BD')
      expect(@stock_repository).not_to have_received(:status_for)
      # Checkpoint A — only the price_range packet adopts v3, carrying the projected presentation policy
      # OUTSIDE facts; the policy was threaded from the composition root through the authority seam.
      expect(@captured[:packet][:evidence_version]).to eq('marine_evidence_v3')
      expect(@captured[:packet][:presentation_policy]).to eq(tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code')
      expect(@captured[:forwarded_policy]).to eq(tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code')
    end

    it 'stock available: a binary-status-only reply (no quantity/location fact keys)' do
      allow(@catalog_resolver).to receive(:call).and_return(resolver_result(status: :exact_child, child_code: 'BD-4'))
      stub_decision(normalized_plan(intents: %w[stock]))
      @model2 = 'Ya, Santorini BD varian BD-4 saat ini tersedia.'

      result = execution.call

      expect(result).to be_deliverable
      expect(@captured[:packet][:response_goals]).to eq(%w[answer_stock])
      expect(@captured[:packet][:facts].keys).to eq(%i[stock])
      stock = @captured[:packet][:facts][:stock]
      expect(stock.keys).to eq(%i[status source checked_at])
      expect(stock[:status]).to eq('available')
      expect(@price_repository).not_to have_received(:price_for)
    end

    it 'stock unavailable: the binary status is the only fact, still delivered through the same seam' do
      allow(@catalog_resolver).to receive(:call).and_return(resolver_result(status: :exact_child, child_code: 'BD-4'))
      allow(@stock_repository).to receive(:status_for).with('BD-4').and_return(:empty)
      stub_decision(normalized_plan(intents: %w[stock]))
      @model2 = 'Mohon maaf, Santorini BD varian BD-4 saat ini tidak tersedia.'

      result = execution.call

      expect(result).to be_deliverable
      expect(@captured[:packet][:facts][:stock]).to include(status: 'unavailable')
      expect(@captured[:packet][:facts][:stock].keys).to eq(%i[status source checked_at])
    end
  end

  # ================================================================================================
  # 2. One Decision runner call, the exact plan forwarded, and Model 2 input isolation.
  # ================================================================================================
  describe 'single Model 1 call, exact plan forwarding, and Model 2 input isolation' do
    it 'makes exactly one Decision runner call and forwards the exact CandidatePlan object to the authority' do
      allow(@catalog_resolver).to receive(:call).and_return(resolver_result(status: :exact_child, child_code: 'BD-4'))
      stub_decision(normalized_plan(intents: %w[price]))
      @model2 = 'Harga Santorini BD varian BD-4 adalah Rp 12.500 per yard.'

      execution.call

      expect(@decision_runner).to have_received(:call).once
      expect(@captured[:forwarded_plan]).to equal(@plan)
    end

    it 'passes Model 2 collaborators only the packet and bounded context, never a repository handle' do
      allow(@catalog_resolver).to receive(:call).and_return(resolver_result(status: :exact_child, child_code: 'BD-4'))
      stub_decision(normalized_plan(intents: %w[price]))
      @model2 = 'Harga Santorini BD varian BD-4 adalah Rp 12.500 per yard.'

      execution.call

      expect(@captured[:generator_args]).to eq(%i[system messages])
      expect(@captured[:verifier_args]).to eq(%i[packet candidate])
      expect(@captured[:packet]).to be_frozen
      repositories = [@family_repository, @variant_resolver, @price_repository, @stock_repository,
                      @listing_repository, @range_authority, @catalog_resolver, @description_source]
      expect(repositories).not_to include(@captured[:candidate])
      expect(@captured[:packet].values).not_to include(*repositories)
    end
  end

  # ================================================================================================
  # 3. The fail-closed matrix: every ineligible / rejected / mutated outcome folds to the legacy
  #    fallback Result, and the model / repositories are reached only where the contract allows.
  # ================================================================================================
  describe 'fail-closed boundaries' do
    it 'rejects an unauthorized mixed plan BEFORE any authority repository read' do
      stub_decision(normalized_plan(intents: %w[price stock]))

      result = execution.call

      expect(result).not_to be_deliverable
      expect(result.status).to eq(:fallback)
      expect(@catalog_resolver).not_to have_received(:call)
      expect(@family_repository).not_to have_received(:resolve_exact)
      expect(@price_repository).not_to have_received(:price_for)
      expect(@stock_repository).not_to have_received(:status_for)
      expect(@generator).not_to have_received(:call)
    end

    it 'falls back (no Model 2 call) when no exact catalog identity matches' do
      allow(@catalog_resolver).to receive(:call).and_return(
        resolver_result(status: :no_catalog_match, source: :none, family_code: nil, family_name: nil,
                        reason: :candidate_context_insufficient)
      )
      stub_decision(normalized_plan(intents: %w[price]))

      result = execution.call

      expect(result).not_to be_deliverable
      expect(result.status).to eq(:fallback)
      expect(@generator).not_to have_received(:call)
      expect(@price_repository).not_to have_received(:price_for)
    end

    it 'falls back (no Model 2 call) on a repository authority outage — an invalid Evidence packet' do
      allow(@catalog_resolver).to receive(:call).and_return(resolver_result(status: :exact_child, child_code: 'BD-4'))
      allow(@price_repository).to receive(:price_for).with('BD-4').and_return(status: :unavailable)
      stub_decision(normalized_plan(intents: %w[price]))

      result = execution.call

      expect(result).not_to be_deliverable
      expect(result.status).to eq(:fallback)
      expect(@generator).not_to have_received(:call)
    end

    # Step 18 — for exact_price the untrusted Model 2 candidate is still DISCARDED at every gate, but the
    # turn no longer falls back to the legacy path: the deterministic price Evidence is rendered and
    # delivered (ok=true). These three prove the discard holds AND the deterministic Evidence is delivered.
    it 'renders deterministic exact-price Evidence when Model 2 generation fails (candidate never reaches the verifier)' do
      allow(@catalog_resolver).to receive(:call).and_return(resolver_result(status: :exact_child, child_code: 'BD-4'))
      stub_decision(normalized_plan(intents: %w[price]))
      @model2 = nil

      result = execution.call

      expect(result).to be_deliverable
      expect(result.text).to eq('Harga BD-4 adalah Rp 12.500 per yard.')
      expect(@fact_verifier).not_to have_received(:call)
    end

    it 'discards a candidate the deterministic Fact Guard rejects and renders deterministic exact-price Evidence' do
      allow(@catalog_resolver).to receive(:call).and_return(resolver_result(status: :exact_child, child_code: 'BD-4'))
      stub_decision(normalized_plan(intents: %w[price]))
      @model2 = 'Harga Santorini BD varian BD-4 adalah Rp 99.999 per yard.'

      result = execution.call

      expect(result).to be_deliverable
      expect(result.text).to eq('Harga BD-4 adalah Rp 12.500 per yard.')
      expect(result.text).not_to include('99.999')
      expect(@fact_verifier).not_to have_received(:call)
    end

    it 'discards a semantically-rejected but fact-clean candidate and renders deterministic exact-price Evidence' do
      allow(@catalog_resolver).to receive(:call).and_return(resolver_result(status: :exact_child, child_code: 'BD-4'))
      stub_decision(normalized_plan(intents: %w[price]))
      @model2 = 'Harga Santorini BD varian BD-4 adalah Rp 12.500 per yard.'
      @verdict = false

      result = execution.call

      expect(result).to be_deliverable
      expect(result.text).to eq('Harga BD-4 adalah Rp 12.500 per yard.')
      expect(@fact_verifier).to have_received(:call).once
    end

    it 'discards a stock candidate that smuggles a quantity and renders deterministic binary-stock Evidence' do
      allow(@catalog_resolver).to receive(:call).and_return(resolver_result(status: :exact_child, child_code: 'BD-4'))
      stub_decision(normalized_plan(intents: %w[stock]))
      @model2 = 'Ya, Santorini BD varian BD-4 tersedia, ada 25 unit di gudang.'

      result = execution.call

      expect(result).to be_deliverable
      expect(result.text).to eq('BD-4 saat ini tersedia.')
      # The smuggled quantity / warehouse claim never reaches the customer.
      expect(result.text).not_to match(/25|unit|gudang/)
      expect(@fact_verifier).not_to have_received(:call)
    end
  end
end
