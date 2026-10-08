# frozen_string_literal: true

require 'rails_helper'

# Phase 2A — the AuthorityCoordinator closing seam. It uses the REAL
# CandidatePlanToProductIntentAdapter for schema/scenario/intent authorization grounded on the backend
# ExecutionPolicy (so the fail-closed contract is exercised end to end) and injected doubles for the
# resolver / planner / packet builder / range authority / language resolver so no catalog DB or
# provider is touched.
#
# These examples pin §6/§7: the exact `["price"]` ExecutionPolicy gate (every other single/multi intent
# stops BEFORE any fact repository call — the resolver is never even consulted), the FRESH resolver-sourced
# planner input (JEV slot_operations never source an identifier), language injection + nil fail-closed,
# the exact family+child packet vs clean family-only range dispatch, the closed fail-closed matrix, and
# the deep-frozen closed Result.
RSpec.describe Marine::Backend::AuthorityCoordinator do
  subject(:coordinator) do
    described_class.new(resolver: resolver, planner: planner, packet_builder: packet_builder,
                        range_authority: range_authority, language_resolver: language_resolver)
  end

  let(:resolver) { instance_double(Marine::Backend::CatalogCandidateResolver) }
  let(:planner) { instance_double(Marine::Backend::ProductExecutionPlanner) }
  let(:packet_builder) { instance_double(Marine::Backend::EvidencePacketBuilder) }
  let(:range_authority) { instance_double(Marine::Backend::FamilyPriceRangeAuthority) }
  let(:language_resolver) { class_double(Marine::Catalog::ConversationLanguageResolver) }

  def raw_plan(intents: %w[price], key: 'scenario_5', conf: 'high')
    {
      'schema_version' => 'marine_decision_v1',
      'scenario_candidate' => { 'key' => key, 'confidence' => conf },
      'intents' => intents,
      'slot_operations' => [{ 'operation' => 'set', 'slot' => 'product',
                              'value' => { 'raw_candidate' => 'JEV-SUGGESTED', 'candidate_type' => 'display_name' } }],
      'customer_language' => 'id',
      'confidence' => conf
    }
  end

  def plan(**)
    Marine::Decision::CandidatePlan.normalize(raw_plan(**))
  end

  def resolved(status:, source: :current_turn, family_code: 'FAM1', family_name: 'Hull', child_code: nil, reason: :accepted) # rubocop:disable Metrics/ParameterLists -- a flat resolver-Result builder for the examples
    Marine::Backend::CatalogCandidateResolver::Result.new(
      status: status, source: source, family_code: family_code, family_name: family_name,
      child_code: child_code, reason: reason
    ).freeze
  end

  def call(candidate_plan: plan, scenario_key: 'scenario_5', # rubocop:disable Metrics/ParameterLists -- a flat keyword call-helper mirroring the coordinator signature
           trigger: 'berapa harga FAM1', history: [], flow_state: nil, configured_language: 'id')
    coordinator.call(candidate_plan: candidate_plan, scenario_key: scenario_key,
                     trigger: trigger, history: history,
                     phase: :follow_up, flow_state: flow_state, configured_language: configured_language)
  end

  before do
    allow(language_resolver).to receive(:resolve).and_return(double('lang', language: 'id'))
    # Stub the dispatch collaborators as spies so `(not_)to have_received` is reliable; individual
    # examples override the return values they care about.
    allow(resolver).to receive(:call)
    allow(planner).to receive(:call)
  end

  describe 'adapter authorization failures' do
    it 'stops on a scenario mismatch' do
      result = call(scenario_key: 'scenario_9')

      expect(result.outcome_type).to eq(:stop)
      expect(result.reason).to eq(:scenario_mismatch)
    end

    it 'stops (unsupported_plan) for a non-product intent that fails closed at the adapter' do
      result = call(candidate_plan: plan(intents: %w[order_status]))

      expect(result.outcome_type).to eq(:stop)
      expect(result.reason).to eq(:unsupported_plan)
    end
  end

  describe 'ExecutionPolicy whole-set gate (exact ["price"]; backend-owned)' do
    it 'preserves legacy (phase_not_executable) for a supported-but-unauthorized single intent WITHOUT any fact call' do
      result = call(candidate_plan: plan(intents: %w[catalog]))

      expect(result.outcome_type).to eq(:legacy_preserved)
      expect(result.reason).to eq(:phase_not_executable)
      expect(resolver).not_to have_received(:call)
    end

    it 'preserves legacy for price+stock (no partial price/range, StockRepository never reached)' do
      result = call(candidate_plan: plan(intents: %w[price stock]))

      expect(result.outcome_type).to eq(:legacy_preserved)
      expect(result.reason).to eq(:phase_not_executable)
      expect(resolver).not_to have_received(:call)
    end

    # The deployed exact-price ambiguity: Model 1 returns price + price_range. The coordinator must NOT
    # collapse it to price here — the authoritative exact-child signal (the resolver) is only computed
    # AFTER this gate, so collapsing would require an unsafe pre-policy catalog read. It stays
    # fail-closed to legacy, and the resolver is never consulted (no pre-policy repository read).
    it 'preserves legacy for price+price_range without any pre-policy resolver/catalog read' do
      result = call(candidate_plan: plan(intents: %w[price price_range]))

      expect(result.outcome_type).to eq(:legacy_preserved)
      expect(result.reason).to eq(:phase_not_executable)
      expect(resolver).not_to have_received(:call)
    end
  end

  describe 'exact family + child → evidence packet' do
    let(:packet) { { response_goals: %w[answer_price], evidence_version: 'marine_evidence_v2' }.freeze }

    before do
      allow(resolver).to receive(:call).and_return(resolved(status: :exact_child, child_code: 'FAM1-CHILD'))
      allow(packet_builder).to receive(:build).and_return(packet)
    end

    it 'builds a FRESH planner input sourced from the resolver/language — never from JEV slot_operations' do
      captured = nil
      allow(planner).to receive(:call) { |**kwargs|
        captured = kwargs
        { planner: :input }
      }

      result = call

      expect(captured[:intents]).to eq(%w[price])
      expect(captured[:scenario]).to eq(key: 'scenario_5')
      expect(captured[:product_intent]).to include(
        family_mention: 'FAM1', explicit_child_code: 'FAM1-CHILD', attribute_candidates: [],
        customer_language: 'id', intent: 'price', requested_intents: %w[price],
        requires_exact_variant: true, quantity_inquiry: false
      )
      # The JEV-suggested display name never reaches the planner input.
      expect(captured[:product_intent][:family_mention]).not_to eq('JEV-SUGGESTED')
      expect(result.outcome_type).to eq(:evidence_packet)
      expect(result.reason).to eq(:accepted)
      expect(result.evidence_packet).to equal(packet)
      expect(result.price_range).to be_nil
      expect(result.source).to eq(:current_turn)
      expect(result).to be_frozen
    end

    it 'maps a planner handoff goal to handoff/price_unavailable (may carry the packet)' do
      allow(planner).to receive(:call).and_return({ planner: :input })
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[handoff] }.freeze)

      result = call

      expect(result.outcome_type).to eq(:handoff)
      expect(result.reason).to eq(:price_unavailable)
    end

    it 'maps a planner clarify goal to clarify/variant_ambiguous (revalidation conflict)' do
      allow(planner).to receive(:call).and_return({ planner: :input })
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[clarify_ambiguous_variant] }.freeze)

      result = call

      expect(result.outcome_type).to eq(:clarify)
      expect(result.reason).to eq(:variant_ambiguous)
    end
  end

  describe 'Phase 3 — single listing / information path (no catalog-identity resolver)' do
    let(:listing_packet) { { response_goals: %w[answer_product_listing], evidence_version: 'marine_evidence_v2' }.freeze }

    before { allow(packet_builder).to receive(:build).and_return(listing_packet) }

    it 'routes a listing intent to the bounded listing planner input, bypassing the resolver' do
      captured = nil
      allow(planner).to receive(:call) { |**kwargs|
        captured = kwargs
        { planner: :input }
      }

      result = call(candidate_plan: plan(intents: %w[product_listing]), trigger: 'produk apa saja?')

      expect(resolver).not_to have_received(:call)
      expect(captured[:intents]).to eq(%w[product_listing])
      expect(captured[:product_intent]).to include(
        intent: 'product_listing', requested_intents: [], requires_exact_variant: false,
        explicit_child_code: nil, customer_language: 'id', family_mention: 'JEV-SUGGESTED'
      )
      expect(result.outcome_type).to eq(:evidence_packet)
      expect(result.reason).to eq(:accepted)
      expect(result.evidence_packet).to equal(listing_packet)
      expect(result.source).to eq(:none)
      expect(result).to be_frozen
    end

    it 'accepts a product_information listing packet too' do
      allow(packet_builder).to receive(:build).and_return(
        { response_goals: %w[answer_product_information], evidence_version: 'marine_evidence_v2' }.freeze
      )
      result = call(candidate_plan: plan(intents: %w[product_information]))
      expect(result.outcome_type).to eq(:evidence_packet)
      expect(result.reason).to eq(:accepted)
    end

    it 'hands off (catalog_unavailable) when the listing planner produced a factless handoff' do
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[handoff] }.freeze)
      result = call(candidate_plan: plan(intents: %w[product_listing]))
      expect(result.outcome_type).to eq(:handoff)
      expect(result.reason).to eq(:catalog_unavailable)
    end

    it 'hands off (language_unresolved) on a nil language WITHOUT calling the planner' do
      allow(language_resolver).to receive(:resolve).and_return(double('lang', language: nil))
      result = call(candidate_plan: plan(intents: %w[product_listing]))
      expect(result.outcome_type).to eq(:handoff)
      expect(result.reason).to eq(:language_unresolved)
      expect(planner).not_to have_received(:call)
    end
  end

  describe 'exact family (no child) → family price range' do
    before { allow(resolver).to receive(:call).and_return(resolved(status: :exact_family)) }

    it 'returns family_price_range/accepted for an available range' do
      range = Marine::Backend::FamilyPriceRangeAuthority::Result.new(status: :available, min: '10', max: '20',
                                                                     currency: 'IDR', uom: 'Meter', source: 's', checked_at: 't').freeze
      allow(range_authority).to receive(:call).with(family_code: 'FAM1').and_return(range)

      result = call

      expect(result.outcome_type).to eq(:family_price_range)
      expect(result.reason).to eq(:accepted)
      expect(result.price_range).to equal(range)
      expect(result.evidence_packet).to be_nil
    end

    it 'hands off (range_unavailable) when the range is unavailable' do
      allow(range_authority).to receive(:call).and_return(
        Marine::Backend::FamilyPriceRangeAuthority::Result.new(status: :range_unavailable).freeze
      )

      result = call

      expect(result.outcome_type).to eq(:handoff)
      expect(result.reason).to eq(:range_unavailable)
    end

    it 'hands off (catalog_unavailable) on a range outage' do
      allow(range_authority).to receive(:call).and_return(
        Marine::Backend::FamilyPriceRangeAuthority::Result.new(status: :outage).freeze
      )

      expect(call.reason).to eq(:catalog_unavailable)
    end
  end

  describe 'Phase 5 — explicit price_range / stock routed to Evidence v2 (same resolver + planner + builder)' do
    it 'routes price_range through the resolver (family identity) with a family-level planner input' do
      allow(resolver).to receive(:call).and_return(resolved(status: :exact_family))
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[answer_price_range], evidence_version: 'marine_evidence_v2' }.freeze)
      captured = nil
      allow(planner).to receive(:call) { |**kwargs|
        captured = kwargs
        { planner: :input }
      }

      result = call(candidate_plan: plan(intents: %w[price_range]))

      expect(resolver).to have_received(:call)
      expect(captured[:intents]).to eq(%w[price_range])
      expect(captured[:product_intent]).to include(
        family_mention: 'FAM1', intent: 'price_range', requested_intents: %w[price_range], requires_exact_variant: false
      )
      expect(captured[:product_intent][:family_mention]).not_to eq('JEV-SUGGESTED')
      expect(result.outcome_type).to eq(:evidence_packet)
      expect(result.reason).to eq(:accepted)
    end

    it 'routes stock through the resolver (exact child) requiring an exact variant' do
      allow(resolver).to receive(:call).and_return(resolved(status: :exact_child, child_code: 'FAM1-CHILD'))
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[answer_stock], evidence_version: 'marine_evidence_v2' }.freeze)
      captured = nil
      allow(planner).to receive(:call) { |**kwargs|
        captured = kwargs
        { planner: :input }
      }

      result = call(candidate_plan: plan(intents: %w[stock]))

      expect(captured[:intents]).to eq(%w[stock])
      expect(captured[:product_intent]).to include(
        intent: 'stock', requested_intents: %w[stock], explicit_child_code: 'FAM1-CHILD', requires_exact_variant: true
      )
      expect(result.outcome_type).to eq(:evidence_packet)
      expect(result.reason).to eq(:accepted)
    end

    it 'maps a planner handoff to range_unavailable / stock_unavailable respectively' do
      allow(resolver).to receive(:call).and_return(resolved(status: :exact_child, child_code: 'FAM1-CHILD'))
      allow(planner).to receive(:call).and_return({ planner: :input })
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[handoff] }.freeze)

      expect(call(candidate_plan: plan(intents: %w[price_range])).reason).to eq(:range_unavailable)
      expect(call(candidate_plan: plan(intents: %w[stock])).reason).to eq(:stock_unavailable)
    end

    it 'maps a planner clarify (stock without an exact variant) to a clarify outcome' do
      allow(resolver).to receive(:call).and_return(resolved(status: :exact_family))
      allow(planner).to receive(:call).and_return({ planner: :input })
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[clarify_variant] }.freeze)

      result = call(candidate_plan: plan(intents: %w[stock]))
      expect(result.outcome_type).to eq(:clarify)
    end

    it 'preserves legacy on no catalog match, hands off on outage, and never defaults an unknown status to a fact' do
      allow(resolver).to receive(:call).and_return(resolved(status: :no_catalog_match, source: :none, family_code: nil, family_name: nil,
                                                            reason: :candidate_context_insufficient))
      expect(call(candidate_plan: plan(intents: %w[price_range])).outcome_type).to eq(:legacy_preserved)

      allow(resolver).to receive(:call).and_return(resolved(status: :unavailable, source: :none, reason: :catalog_unavailable))
      expect(call(candidate_plan: plan(intents: %w[stock])).reason).to eq(:catalog_unavailable)
    end

    it 'hands off (language_unresolved) on a nil language WITHOUT calling the planner' do
      allow(resolver).to receive(:call).and_return(resolved(status: :exact_family))
      allow(language_resolver).to receive(:resolve).and_return(double('lang', language: nil))

      result = call(candidate_plan: plan(intents: %w[price_range]))
      expect(result.outcome_type).to eq(:handoff)
      expect(result.reason).to eq(:language_unresolved)
      expect(planner).not_to have_received(:call)
    end

    # Checkpoint A — the presentation policy is threaded into the planner ONLY on the price_range answer;
    # the stock answer never receives it (so the stock packet stays v2).
    it 'threads the presentation policy into the price_range planner input but NOT the stock one' do
      policy = { tone: 'casual', verbosity: 'detailed', range_followup_mode: 'ask_variant_code' }
      captured = nil
      allow(planner).to receive(:call) do |**kwargs|
        captured = kwargs
        { planner: :input }
      end
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[answer_price_range] }.freeze)

      allow(resolver).to receive(:call).and_return(resolved(status: :exact_family))
      coordinator.call(candidate_plan: plan(intents: %w[price_range]), scenario_key: 'scenario_5',
                       trigger: 'berapa kisaran harga FAM1', history: [], phase: :follow_up,
                       flow_state: nil, configured_language: 'id', presentation_policy: policy)
      expect(captured[:presentation_policy]).to eq(policy)

      allow(resolver).to receive(:call).and_return(resolved(status: :exact_child, child_code: 'FAM1-CHILD'))
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[answer_stock] }.freeze)
      coordinator.call(candidate_plan: plan(intents: %w[stock]), scenario_key: 'scenario_5',
                       trigger: 'apakah FAM1 tersedia', history: [], phase: :follow_up,
                       flow_state: nil, configured_language: 'id', presentation_policy: policy)
      expect(captured[:presentation_policy]).to be_nil
    end
  end

  describe 'language resolution' do
    it 'hands off (language_unresolved) on a nil language WITHOUT calling the planner' do
      allow(resolver).to receive(:call).and_return(resolved(status: :exact_child, child_code: 'FAM1-CHILD'))
      allow(language_resolver).to receive(:resolve).and_return(double('lang', language: nil))

      result = call

      expect(result.outcome_type).to eq(:handoff)
      expect(result.reason).to eq(:language_unresolved)
      expect(planner).not_to have_received(:call)
    end
  end

  describe 'resolver fail-closed statuses' do
    it 'preserves legacy (candidate_context_insufficient) for no exact catalog match' do
      allow(resolver).to receive(:call).and_return(resolved(status: :no_catalog_match, source: :none,
                                                            family_code: nil, family_name: nil,
                                                            reason: :candidate_context_insufficient))
      result = call

      expect(result.outcome_type).to eq(:legacy_preserved)
      expect(result.reason).to eq(:candidate_context_insufficient)
    end

    it 'clarifies on an ambiguous identity' do
      allow(resolver).to receive(:call).and_return(resolved(status: :ambiguous, source: :none, reason: :variant_ambiguous))

      result = call

      expect(result.outcome_type).to eq(:clarify)
      expect(result.reason).to eq(:variant_ambiguous)
    end

    it 'hands off on a catalog outage' do
      allow(resolver).to receive(:call).and_return(resolved(status: :unavailable, source: :none, reason: :catalog_unavailable))

      expect(call.outcome_type).to eq(:handoff)
      expect(call.reason).to eq(:catalog_unavailable)
    end
  end

  describe 'unexpected internal error' do
    it 'folds a collaborator failure to stop/internal_error' do
      allow(resolver).to receive(:call).and_raise(StandardError, 'boom')

      result = call

      expect(result.outcome_type).to eq(:stop)
      expect(result.reason).to eq(:internal_error)
    end

    # A1 — an out-of-contract resolver status must fail closed to stop/internal_error; it must NEVER
    # fall through to the family price range (that was the latent default-to-range bug).
    it 'stops (internal_error) on an unknown/malformed resolver status and never consults the range' do
      bogus = Marine::Backend::CatalogCandidateResolver::Result.new(
        status: :something_unexpected, source: :current_turn, family_code: 'FAM1',
        family_name: 'Hull', child_code: nil, reason: :accepted
      ).freeze
      allow(resolver).to receive(:call).and_return(bogus)
      allow(range_authority).to receive(:call)

      result = call

      expect(result.outcome_type).to eq(:stop)
      expect(result.reason).to eq(:internal_error)
      expect(range_authority).not_to have_received(:call)
    end
  end

  # B4 — the closed Result must be deep-frozen: the intents array AND every intent String frozen (a
  # frozen array of mutable strings is not deep-frozen).
  describe 'deep immutability of intents' do
    it 'freezes the intents array and every intent String for an accepted price result' do
      allow(resolver).to receive(:call).and_return(resolved(status: :exact_family))
      allow(range_authority).to receive(:call).and_return(
        Marine::Backend::FamilyPriceRangeAuthority::Result.new(
          status: :available, min: '10', max: '20', currency: 'IDR', uom: 'Meter', source: 's', checked_at: 't'
        ).freeze
      )

      result = call

      expect(result.intents).to eq(%w[price])
      expect(result.intents).to be_frozen
      expect(result.intents).to all(be_frozen)
    end

    it 'returns a frozen (empty) intents array for an adapter phase_not_executable result' do
      result = call(candidate_plan: plan(intents: %w[price stock]))

      expect(result.outcome_type).to eq(:legacy_preserved)
      expect(result.reason).to eq(:phase_not_executable)
      expect(result.intents).to eq([])
      expect(result.intents).to be_frozen
    end
  end

  # price_range proposed-state-transition seam. ONLY an accepted price_range answer carries a
  # non-handoff transition (operation :start/:update + the resolver family identity); an ambiguous
  # price_range family carries the SAME closed envelope with handoff_required:true / identity nil and
  # no state write. Every other capability (price / stock / listing / information) carries NO
  # transition, so an existing family state is never overwritten.
  describe 'price_range proposed_state_transition (state_transition_v1)' do
    before do
      allow(packet_builder).to receive(:build).and_return(
        { response_goals: %w[answer_price_range], evidence_version: 'marine_evidence_v3' }.freeze
      )
    end

    def price_range_result(flow_state: nil, status: :exact_family, family_code: 'FAM1', child_code: nil)
      allow(resolver).to receive(:call).and_return(resolved(status: status, family_code: family_code, child_code: child_code))
      call(candidate_plan: plan(intents: %w[price_range]), flow_state: flow_state)
    end

    it 'attaches a closed, deep-frozen :start transition carrying the resolver family identity for a fresh flow' do
      transition = price_range_result(flow_state: nil).proposed_state_transition

      expect(transition).to eq(
        schema_version: 'state_transition_v1', operation: :start, capability: 'price_range',
        handoff_required: false, authoritative_identity: { family_code: 'FAM1', source: 'marine_catalog' }
      )
      expect(transition.keys).to contain_exactly(
        :schema_version, :operation, :capability, :handoff_required, :authoritative_identity
      )
      expect(transition).to be_frozen
      expect(transition[:authoritative_identity]).to be_frozen
      expect(transition[:authoritative_identity][:family_code]).to be_frozen
    end

    it 'sources the identity from the resolver family, never the candidate-plan slot text' do
      transition = price_range_result.proposed_state_transition

      # the plan carried raw_candidate 'JEV-SUGGESTED'; the identity is the resolver family only.
      expect(transition[:authoritative_identity][:family_code]).to eq('FAM1')
    end

    it 'uses :update when the SAME family is already active' do
      result = price_range_result(flow_state: { 'status' => 'active', 'validated_family' => 'FAM1' })
      expect(result.proposed_state_transition[:operation]).to eq(:update)
    end

    it 'uses :start on a family switch (active flow, DIFFERENT family)' do
      result = price_range_result(flow_state: { 'status' => 'active', 'validated_family' => 'OTHER' })
      expect(result.proposed_state_transition[:operation]).to eq(:start)
    end

    it 'uses :start when the active flow has expired' do
      result = price_range_result(flow_state: { 'status' => 'expired', 'validated_family' => 'FAM1' })
      expect(result.proposed_state_transition[:operation]).to eq(:start)
    end

    it 'attaches the SAME closed envelope with handoff_required:true and nil identity on an ambiguous family' do
      allow(resolver).to receive(:call).and_return(resolved(status: :ambiguous, source: :none, reason: :family_ambiguous))

      transition = call(candidate_plan: plan(intents: %w[price_range])).proposed_state_transition

      expect(transition).to eq(
        schema_version: 'state_transition_v1', operation: :start, capability: 'price_range',
        handoff_required: true, authoritative_identity: nil
      )
      expect(transition).to be_frozen
    end

    it 'does not fabricate a family from an ambiguous match (identity stays nil)' do
      allow(resolver).to receive(:call).and_return(resolved(status: :ambiguous, source: :none, reason: :variant_ambiguous))

      expect(call(candidate_plan: plan(intents: %w[price_range])).proposed_state_transition[:authoritative_identity]).to be_nil
    end

    it 'attaches NO transition when no exact catalog family is found (legacy preserved)' do
      allow(resolver).to receive(:call).and_return(resolved(status: :no_catalog_match, source: :none,
                                                            family_code: nil, family_name: nil,
                                                            reason: :candidate_context_insufficient))
      result = call(candidate_plan: plan(intents: %w[price_range]))

      expect(result.outcome_type).to eq(:legacy_preserved)
      expect(result.proposed_state_transition).to be_nil
    end

    it 'attaches NO transition for a stock identity turn' do
      allow(resolver).to receive(:call).and_return(resolved(status: :exact_child, child_code: 'FAM1-CHILD'))
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[answer_stock], evidence_version: 'marine_evidence_v2' }.freeze)

      expect(call(candidate_plan: plan(intents: %w[stock])).proposed_state_transition).to be_nil
    end

    it 'attaches NO transition for a product_listing turn (an existing family state stays untouched)' do
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[answer_product_listing], evidence_version: 'v2' }.freeze)

      expect(call(candidate_plan: plan(intents: %w[product_listing])).proposed_state_transition).to be_nil
    end
  end

  # Bug 2 — the coordinator closes the SAME prior-history asymmetry as the orchestrator: each prior
  # CUSTOMER turn is enriched with its own Catalog-derived trusted tokens (via a REAL CatalogTrustedTokens
  # over an injected read-only family repository) before the REAL ConversationLanguageResolver runs, so a
  # product-name-only prior turn never poisons the strict-sticky delivery language, and a forged
  # `trusted_tokens` on the incoming history is recomputed/overwritten from authoritative rows.
  describe 'Bug 2: per-turn trusted tokens on the prior history (validated-family price path)' do
    subject(:coordinator) do
      described_class.new(resolver: resolver, planner: planner, packet_builder: packet_builder,
                          range_authority: range_authority,
                          language_resolver: Marine::Catalog::ConversationLanguageResolver,
                          catalog_trusted_tokens: Marine::Catalog::CatalogTrustedTokens.new(family_repository: family_repository))
    end

    let(:family_repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }

    before do
      allow(resolver).to receive(:call).and_return(resolved(status: :exact_child, child_code: 'FAM1-CHILD'))
      allow(packet_builder).to receive(:build).and_return({ response_goals: %w[answer_price], evidence_version: 'marine_evidence_v2' }.freeze)
      allow(family_repository).to receive(:active_candidates).and_return([])
      allow(Marine::Llm::LanguageDetector).to receive(:new) do |text|
        result = case text.to_s
                 when 'berapa harganya' then { language: 'id', reliable: true, confidence: 0.99 }
                 when 'linen flow' then { language: 'nl', reliable: true, confidence: 0.99 } # the runtime poison
                 when 'I want fabric' then { language: 'en', reliable: true, confidence: 0.99 }
                 else { language: 'unknown', reliable: false, confidence: 0.0 }
                 end
        instance_double(Marine::Llm::LanguageDetector, detect: result)
      end
    end

    it 'skips a product-only newest prior and inherits the older Indonesian prior (repository per prior turn)' do
      allow(family_repository).to receive(:active_candidates) do |query:, **_|
        %w[linen flow].include?(query) ? [{ code: 'LF', name: 'Linen Flow' }] : []
      end
      history = [{ role: 'user', content: 'berapa harganya' }, { role: 'user', content: 'linen flow' }]

      result = call(trigger: 'FAM1', history: history, configured_language: 'id')

      expect(result.outcome_type).to eq(:evidence_packet)
      expect(Marine::Llm::LanguageDetector).not_to have_received(:new).with('linen flow')
      expect(family_repository).to have_received(:active_candidates).with(query: 'linen', limit: 50)
    end

    it 'discards forged prior trusted_tokens and keeps the English prior (Catalog returns no match)' do
      history = [{ role: 'user', content: 'I want fabric', trusted_tokens: %w[want fabric] }]

      # If the forged tokens were trusted, the prior would be erased and language would NOT be en.
      captured = nil
      allow(planner).to receive(:call) do |**kwargs|
        captured = kwargs[:product_intent]
        { planner: :input }
      end

      call(trigger: 'FAM1', history: history, configured_language: 'id')

      expect(captured[:customer_language]).to eq('en')
      expect(family_repository).to have_received(:active_candidates).with(query: 'want', limit: 50)
      expect(family_repository).to have_received(:active_candidates).with(query: 'fabric', limit: 50)
    end
  end
end
