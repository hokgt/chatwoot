# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Backend::ExactPriceCustomerExecution do
  Coordinator = Marine::Backend::AuthorityCoordinator

  subject(:execution) do
    described_class.new(
      account: account, assistant: assistant, conversation: conversation, message: message,
      decision_runner: decision_runner, scenario_adapter: scenario_adapter,
      authority_execution: authority_execution, presenter: presenter, generator: generator,
      fact_verifier: fact_verifier, context_builder: context_builder, policy_projector: policy_projector
    )
  end

  let(:account) { double(id: 7) }
  let(:assistant) { double(id: 8, account_id: 7) }
  let(:inbox) { double(marine_assistant: assistant) }
  let(:conversation) { double(id: 9, account_id: 7, inbox: inbox) }
  let(:message) { double(conversation_id: 9, incoming?: true, private?: false) }
  let(:context) { Struct.new(:trigger, :history).new('price request', [{ role: 'user', content: 'prior' }]) }
  let(:context_builder) { double(build: context) }
  let(:scenarios) { [{ 'key' => 'scenario_5', 'description' => 'price', 'instruction' => 'answer' }] }
  let(:scenario_adapter) { double(overflow?: false, scenarios: scenarios) }
  let(:candidate_plan) { { marker: Object.new }.freeze }
  let(:decision_runner) { double }
  let(:authority_execution) { double }
  let(:presenter) { double }

  def generator
    @generator ||= double
  end

  def fact_verifier
    @fact_verifier ||= double
  end

  # The projected presentation policy is a plain closed triple; the projector is injected (as a method
  # helper, not a memoized let) so the "exactly once + threaded downstream" contract is assertable
  # without a real assistant.
  def presentation_policy
    @presentation_policy ||= { tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code' }.freeze
  end

  def policy_projector
    @policy_projector ||= double(call: presentation_policy)
  end

  def deep_freeze(value)
    case value
    when Hash
      value.each do |key, child|
        deep_freeze(key)
        deep_freeze(child)
      end
    when Array
      value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end

  def packet(version: 'marine_evidence_v2', goals: %w[answer_price], facts: { price: { display: 'safe' } }, presentation_policy: :none)
    attrs = { evidence_version: version, response_goals: goals, facts: facts }
    attrs[:presentation_policy] = presentation_policy unless presentation_policy == :none
    deep_freeze(attrs)
  end

  # Production-shaped exact-price Evidence fixture: identity is independently present in the product
  # slot, variant slot, and canonical price fact. Display values are deliberately irrelevant to binding.
  def exact_price_packet(family_code: 'BD', variant_code: 'BD-4', canonical_variant_code: variant_code)
    deep_freeze(
      evidence_version: 'marine_evidence_v2', generated_at: '2026-09-30T12:00:00Z',
      response_goals: %w[answer_price], scenario: { key: 'scenario_5', intents: %w[price] },
      validated_slots: {
        product: { code: family_code, name: 'Synthetic family', attributes: {}, source: 'marine_catalog' },
        variant: { code: variant_code, display_name: 'Synthetic variant', attributes: {},
                   resolution_status: 'resolved', source: 'marine_catalog' }
      },
      facts: { price: exact_price_fact(canonical_variant_code) }, missing_slots: [], variant_candidates: [],
      prohibited_claims: %w[exact_stock_quantity warehouse_location delivery_date unverified_discount stock],
      response_constraints: { max_paragraphs: 2, role: 'marine_sales_assistant', handoff_self_reference: true },
      customer_language: 'id'
    )
  end

  def exact_price_fact(variant_code)
    {
      canonical: { variant_code: variant_code, currency: 'IDR', price_list_rate: '12500', uom: 'Yard' },
      display: { product: 'display-is-not-authority', currency: 'Rp', amount: '12.500', uom: 'yard' },
      policy_version: 'price-display-v1', source: 'catalog_price_repository', checked_at: '2026-09-30T12:00:00Z'
    }
  end

  def authority_result(outcome: Coordinator::OUTCOME_EVIDENCE_PACKET,
                       reason: Coordinator::REASON_ACCEPTED, intents: %w[price], evidence_packet: exact_price_packet,
                       proposed_state_transition: :auto)
    proposed_state_transition = exact_price_transition if proposed_state_transition == :auto && intents == %w[price]
    proposed_state_transition = nil if proposed_state_transition == :auto
    Coordinator::Result.new(
      outcome_type: outcome, reason: reason, scenario_key: 'scenario_5',
      intents: deep_freeze(intents), source: :catalog, evidence_packet: evidence_packet,
      proposed_state_transition: proposed_state_transition
    ).freeze
  end

  def exact_price_transition(operation: :start, family_code: 'BD', variant_code: 'BD-4')
    deep_freeze(schema_version: 'state_transition_v1', operation: operation, capability: 'price',
                handoff_required: false,
                authoritative_identity: { family_code: family_code, variant_code: variant_code, source: 'marine_catalog' })
  end

  # A valid, deep-frozen price_range proposed-state-transition envelope (the shape the AuthorityCoordinator
  # emits), used to exercise the consumer-boundary revalidation and threading.
  def price_range_transition(operation: :start, family_code: 'BD', handoff_required: false)
    identity = handoff_required ? nil : { family_code: family_code, source: 'marine_catalog' }
    deep_freeze(schema_version: 'state_transition_v1', operation: operation, capability: 'price_range',
                handoff_required: handoff_required, authoritative_identity: identity)
  end

  def v3_range_packet
    packet(version: 'marine_evidence_v3', goals: %w[answer_price_range],
           facts: { price_range: { display: 'r' } }, presentation_policy: presentation_policy)
  end

  before do
    allow(decision_runner).to receive(:call).and_return(candidate_plan)
    allow(authority_execution).to receive(:call).and_return(authority_result)
    allow(presenter).to receive(:call)
  end

  it 'fails a bad relationship before constructing or calling any collaborator' do
    invalid_message = double(conversation_id: 99, incoming?: true, private?: false)
    collaborators = [context_builder, scenario_adapter, decision_runner, authority_execution,
                     presenter, generator, fact_verifier]
    result = described_class.new(
      account: account, assistant: assistant, conversation: conversation, message: invalid_message,
      decision_runner: decision_runner, scenario_adapter: scenario_adapter,
      authority_execution: authority_execution, presenter: presenter, generator: generator,
      fact_verifier: fact_verifier, context_builder: context_builder
    ).call

    expect(result).to have_attributes(status: :fallback, reason: :relationship_invalid, text: nil)
    collaborators.each { |collaborator| expect(collaborator).not_to have_received(:call) if collaborator.respond_to?(:call) }
    expect(context_builder).not_to have_received(:build)
    expect(scenario_adapter).not_to have_received(:overflow?)
  end

  it 'uses one Model 1 plan through authority and returns only deeply frozen deliverable text' do
    evidence = exact_price_packet
    accepted = authority_result(evidence_packet: evidence)
    wording = Struct.new(:ok?, :text, :reason).new(true, 'BD-4 Rp 12.500 per yard', :accepted)
    allow(authority_execution).to receive(:call).and_return(accepted)

    expect(decision_runner).to receive(:call).once.with(
      message: context.trigger, scenarios: scenarios, context: context.history
    ).and_return(candidate_plan)
    expect(authority_execution).to(
      receive(:call).once.with(candidate_plan: candidate_plan, presentation_policy: presentation_policy).and_return(accepted)
    )
    expect(presenter).to receive(:call).once.with(
      packet: evidence, generator: generator, customer_request: context.trigger,
      message_history: context.history, fact_verifier: fact_verifier
    ).and_return(wording)

    result = execution.call

    expect(result).to be_deliverable
    expect(result).to have_attributes(status: :deliverable, reason: :accepted, text: wording.text)
    expect(result).to be_frozen
    expect(result.text).to be_frozen
    expect(result.to_h.keys).to eq(%i[status reason text transition])
    expect(result.to_h.to_s).not_to include('facts', 'evidence_packet', 'candidate_plan')
    expect(context_builder).to have_received(:build).once
  end

  it 'projects the presentation policy exactly once and threads it only into the authority execution' do
    accepted = authority_result
    allow(authority_execution).to receive(:call).and_return(accepted)
    allow(presenter).to receive(:call).and_return(Struct.new(:ok?, :text, :reason).new(true, 'ok', :accepted))

    execution.call

    expect(policy_projector).to have_received(:call).once
    expect(authority_execution).to have_received(:call).with(candidate_plan: candidate_plan, presentation_policy: presentation_policy)
  end

  it 'fails before Model 1 when the complete enabled scenario seam overflows or is empty' do
    [double(overflow?: true), double(overflow?: false, scenarios: [])].each do |adapter|
      result = described_class.new(
        account: account, assistant: assistant, conversation: conversation, message: message,
        decision_runner: decision_runner, scenario_adapter: adapter,
        authority_execution: authority_execution, presenter: presenter,
        generator: generator, fact_verifier: fact_verifier, context_builder: context_builder
      ).call

      expect(result).to have_attributes(status: :fallback, reason: :scenarios_unavailable)
    end

    expect(decision_runner).not_to have_received(:call)
    expect(authority_execution).not_to have_received(:call)
    expect(presenter).not_to have_received(:call)
  end

  it 'never presents unauthorized, non-price, multi, not-found, clarify, handoff, malformed, or wrong-v2 outcomes' do
    rejected = [
      authority_result(reason: Coordinator::REASON_UNSUPPORTED_PLAN),
      authority_result(intents: %w[catalog]),
      authority_result(intents: %w[price stock]),
      authority_result(outcome: Coordinator::OUTCOME_LEGACY_PRESERVED,
                       reason: Coordinator::REASON_CANDIDATE_CONTEXT_INSUFFICIENT),
      authority_result(outcome: Coordinator::OUTCOME_CLARIFY, reason: Coordinator::REASON_VARIANT_AMBIGUOUS),
      authority_result(outcome: Coordinator::OUTCOME_HANDOFF, reason: Coordinator::REASON_PRICE_UNAVAILABLE),
      Object.new,
      authority_result(evidence_packet: packet(version: 'marine_evidence_v1')),
      authority_result(evidence_packet: packet(goals: %w[answer_price handoff])),
      authority_result(evidence_packet: packet(facts: { price: {}, stock: {} })),
      # Crossed versions fail closed: a v2 answer_price_range (no policy) and a v3 answer_price (with policy).
      authority_result(intents: %w[price_range],
                       evidence_packet: packet(version: 'marine_evidence_v2', goals: %w[answer_price_range],
                                               facts: { price_range: { display: 'r' } })),
      authority_result(evidence_packet: packet(version: 'marine_evidence_v3', goals: %w[answer_price],
                                               facts: { price: { display: 'x' } }, presentation_policy: presentation_policy))
    ]

    rejected.each do |authority_outcome|
      allow(authority_execution).to receive(:call).and_return(authority_outcome)
      result = execution.call
      expect(result).not_to be_deliverable
      expect(result.status).to eq(:fallback)
    end

    expect(presenter).not_to have_received(:call)
  end

  it 'folds presenter generation and fact-verification failures to fallback without exposing details' do
    %i[generation_failed fact_rejected fact_unverified].each do |reason|
      failed = Struct.new(:ok?, :text, :reason).new(false, nil, reason)
      allow(presenter).to receive(:call).and_return(failed)

      result = execution.call

      expect(result).to have_attributes(status: :fallback, reason: :presentation_rejected, text: nil)
      expect(result.to_h.keys).to eq(%i[status reason text transition])
    end
  end

  it 'passes Model 2 collaborators only the packet and bounded context, never authority repositories' do
    wording = Struct.new(:ok?, :text).new(true, 'safe exact price')
    allow(presenter).to receive(:call) do |arguments|
      expect(arguments.keys).to contain_exactly(
        :packet, :generator, :customer_request, :message_history, :fact_verifier
      )
      expect(arguments[:packet]).to be_frozen
      expect(arguments.values).not_to include(authority_execution)
      wording
    end

    expect(execution.call).to be_deliverable
    expect(presenter).to have_received(:call).once
  end

  describe 'Phase 3 — one Model 1 attempt routes price, product_listing, or product_information' do
    def listing_packet(goals)
      packet(goals: goals, facts: { product_listing: { products: [{ code: 'AAA', name: 'Alpha' }] } })
    end

    it 'delivers a bounded product_listing target through the single generalized attempt' do
      accepted = authority_result(intents: %w[product_listing], evidence_packet: listing_packet(%w[answer_product_listing]))
      allow(authority_execution).to receive(:call).and_return(accepted)
      allow(presenter).to receive(:call).and_return(Struct.new(:ok?, :text, :reason).new(true, 'Berikut produk: AAA (Alpha).', :accepted))

      result = execution.call
      expect(result).to be_deliverable
      expect(result.text).to eq('Berikut produk: AAA (Alpha).')
    end

    it 'delivers a product_information target (same single Model 1 call per turn)' do
      accepted = authority_result(intents: %w[product_information], evidence_packet: listing_packet(%w[answer_product_information]))
      allow(authority_execution).to receive(:call).and_return(accepted)
      allow(presenter).to receive(:call).and_return(Struct.new(:ok?, :text, :reason).new(true, 'AAA (Alpha): info.', :accepted))

      expect(decision_runner).to receive(:call).once.and_return(candidate_plan)
      expect(execution.call).to be_deliverable
    end

    it 'still rejects a listing packet whose facts do not match the listing goal' do
      mismatch = authority_result(intents: %w[product_listing],
                                  evidence_packet: packet(goals: %w[answer_product_listing], facts: { price: { display: 'x' } }))
      allow(authority_execution).to receive(:call).and_return(mismatch)
      expect(execution.call).not_to be_deliverable
      expect(presenter).not_to have_received(:call)
    end
  end

  describe 'exact-price authoritative state transition' do
    it 'requires and threads identity exactly bound to every authoritative field in a production-shaped packet' do
      transition = exact_price_transition
      evidence = exact_price_packet
      allow(authority_execution).to receive(:call).and_return(
        authority_result(evidence_packet: evidence, proposed_state_transition: transition)
      )
      allow(presenter).to receive(:call).and_return(Struct.new(:ok?, :text, :reason).new(true, 'Harga aman.', :accepted))

      result = execution.call

      expect(result).to be_deliverable
      expect(result.transition).to equal(transition)
      expect(presenter).to have_received(:call).with(hash_including(packet: evidence))
    end

    it 'fails closed before presentation for family, variant-slot, or canonical-price identity forgery' do
      mismatches = [
        [exact_price_transition(family_code: 'FORGED-FAMILY'), exact_price_packet],
        [exact_price_transition(variant_code: 'FORGED-VARIANT'), exact_price_packet],
        [exact_price_transition, exact_price_packet(variant_code: 'OTHER-VARIANT')],
        [exact_price_transition, exact_price_packet(canonical_variant_code: 'OTHER-CANONICAL')],
        [exact_price_transition, exact_price_packet(family_code: nil)]
      ]

      mismatches.each do |transition, evidence|
        allow(authority_execution).to receive(:call).and_return(
          authority_result(evidence_packet: evidence, proposed_state_transition: transition)
        )
        expect(execution.call).to have_attributes(status: :fallback, reason: :transition_required, transition: nil)
      end
      expect(presenter).not_to have_received(:call)
    end

    it 'fails closed before presentation when an accepted exact-price result has no transition' do
      allow(authority_execution).to receive(:call).and_return(authority_result(proposed_state_transition: nil))

      expect(execution.call).to have_attributes(status: :fallback, reason: :transition_required, transition: nil)
      expect(presenter).not_to have_received(:call)
    end

    it 'rejects malformed or forged exact-price identities and crossed capability envelopes' do
      malformed = [
        deep_freeze(schema_version: 'state_transition_v1', operation: :start, capability: 'price',
                    handoff_required: false, authoritative_identity: { family_code: 'BD', source: 'marine_catalog' }),
        deep_freeze(schema_version: 'state_transition_v1', operation: :start, capability: 'price',
                    handoff_required: false,
                    authoritative_identity: { family_code: 'BD', variant_code: 'BD-4', source: 'forged' }),
        deep_freeze(schema_version: 'state_transition_v1', operation: :start, capability: 'price',
                    handoff_required: false,
                    authoritative_identity: { family_code: 'BD', variant_code: 'BD-4', source: 'marine_catalog', price: '12500' }),
        price_range_transition
      ]

      malformed.each do |transition|
        allow(authority_execution).to receive(:call).and_return(authority_result(proposed_state_transition: transition))
        expect(execution.call).to have_attributes(status: :fallback, reason: :transition_required, transition: nil)
      end
      expect(presenter).not_to have_received(:call)
    end
  end

  describe 'Phase 5 — the same single attempt delivers an exact-shape price_range / stock target' do
    it 'delivers a price_range target (carrying its transition) for the exact v3 shape with a valid policy AND a valid transition' do
      transition = price_range_transition(operation: :start, family_code: 'BD')
      accepted = authority_result(intents: %w[price_range], evidence_packet: v3_range_packet, proposed_state_transition: transition)
      allow(authority_execution).to receive(:call).and_return(accepted)
      allow(presenter).to receive(:call).and_return(Struct.new(:ok?, :text, :reason).new(true, 'Kisaran harga BD: Rp 10.000–12.500 per yard.',
                                                                                         :accepted))

      result = execution.call
      expect(result).to be_deliverable
      expect(result.text).to eq('Kisaran harga BD: Rp 10.000–12.500 per yard.')
      # The validated non-handoff transition is threaded through so the job can persist family state.
      expect(result.transition).to eq(transition)
    end

    # price_range delivery REQUIRES a valid non-handoff transition: a missing one fails closed to the
    # fallback (the trigger-bound job then runs legacy reasoning OUTSIDE the lock), so a range reply is
    # never delivered without the authoritative family state it must persist.
    it 'fails closed (fallback, presenter untouched) for a price_range target with NO transition' do
      accepted = authority_result(intents: %w[price_range], evidence_packet: v3_range_packet, proposed_state_transition: nil)
      allow(authority_execution).to receive(:call).and_return(accepted)

      result = execution.call
      expect(result).to have_attributes(status: :fallback, reason: :transition_required, text: nil)
      expect(presenter).not_to have_received(:call)
    end

    # Consumer-boundary revalidation: a forged/unknown-shape or shallow-frozen transition is rejected
    # exactly like a missing one, so a tampered envelope can never drive a delivery or a state write.
    it 'rejects a price_range target whose transition is shallow-frozen or carries unknown/forbidden keys' do
      shallow = { schema_version: 'state_transition_v1', operation: :start, capability: 'price_range',
                  handoff_required: false, authoritative_identity: { family_code: 'BD', source: 'marine_catalog' } }.freeze # inner hashes NOT frozen
      forbidden_keys = deep_freeze(schema_version: 'state_transition_v1', operation: :start, capability: 'price_range',
                                   handoff_required: false, authoritative_identity: { family_code: 'BD', source: 'marine_catalog' },
                                   price: '12500')
      bad_source = deep_freeze(schema_version: 'state_transition_v1', operation: :start, capability: 'price_range',
                               handoff_required: false, authoritative_identity: { family_code: 'BD', source: 'forged' })
      [shallow, forbidden_keys, bad_source].each do |transition|
        accepted = authority_result(intents: %w[price_range], evidence_packet: v3_range_packet, proposed_state_transition: transition)
        allow(authority_execution).to receive(:call).and_return(accepted)

        expect(execution.call).to have_attributes(status: :fallback, reason: :transition_required)
      end
      expect(presenter).not_to have_received(:call)
    end

    # Catalog ambiguity: the coordinator attaches a handoff_required:true envelope (identity nil). The
    # execution surfaces a dedicated :handoff Result carrying it and NEVER touches the presenter/renderer,
    # so no visible text is derived from the ambiguity.
    it 'surfaces a :handoff Result (presenter untouched) for an ambiguous-family handoff transition' do
      transition = price_range_transition(handoff_required: true)
      ambiguous = authority_result(outcome: Coordinator::OUTCOME_CLARIFY, reason: Coordinator::REASON_FAMILY_AMBIGUOUS,
                                   intents: %w[price_range], evidence_packet: nil, proposed_state_transition: transition)
      allow(authority_execution).to receive(:call).and_return(ambiguous)

      result = execution.call
      expect(result).to have_attributes(status: :handoff, text: nil)
      expect(result.handoff?).to be(true)
      expect(result.transition).to eq(transition)
      expect(presenter).not_to have_received(:call)
    end

    it 'a non-price_range (stock) deliverable carries NO transition (state untouched for other capabilities)' do
      accepted = authority_result(intents: %w[stock], evidence_packet: packet(goals: %w[answer_stock], facts: { stock: { status: 'available' } }))
      allow(authority_execution).to receive(:call).and_return(accepted)
      allow(presenter).to receive(:call).and_return(Struct.new(:ok?, :text, :reason).new(true, 'BD-4 tersedia.', :accepted))

      result = execution.call
      expect(result).to be_deliverable
      expect(result.transition).to be_nil
    end

    it 'delivers a stock target only for the exact answer_stock => [:stock] shape' do
      accepted = authority_result(intents: %w[stock], evidence_packet: packet(goals: %w[answer_stock], facts: { stock: { status: 'available' } }))
      allow(authority_execution).to receive(:call).and_return(accepted)
      allow(presenter).to receive(:call).and_return(Struct.new(:ok?, :text, :reason).new(true, 'BD-4 tersedia.', :accepted))

      expect(execution.call).to be_deliverable
    end

    it 'rejects (fallback, presenter untouched) a price_range goal whose facts do not match the closed matrix' do
      mismatch = authority_result(intents: %w[price_range],
                                  evidence_packet: packet(goals: %w[answer_price_range], facts: { price: { display: 'x' } }))
      allow(authority_execution).to receive(:call).and_return(mismatch)

      expect(execution.call).not_to be_deliverable
      expect(presenter).not_to have_received(:call)
    end

    # Defense in depth — the delivery seam's own valid_presentation_policy? gate rejects a v3 range packet
    # carrying a bad-enum policy value BEFORE the presenter, so a malformed policy never reaches Model 2.
    it 'rejects (fallback, presenter untouched) a v3 range packet whose presentation_policy has a bad enum value' do
      bad_policy = authority_result(
        intents: %w[price_range],
        evidence_packet: packet(version: 'marine_evidence_v3', goals: %w[answer_price_range],
                                facts: { price_range: { display: 'r' } },
                                presentation_policy: { tone: 'sarcastic', verbosity: 'concise', range_followup_mode: 'ask_variant_code' })
      )
      allow(authority_execution).to receive(:call).and_return(bad_policy)

      result = execution.call
      expect(result).to have_attributes(status: :fallback, reason: :invalid_packet)
      expect(presenter).not_to have_received(:call)
    end
  end

  # Step 17 — the customer execution seam itself returns a DELIVERABLE for a listing semantic
  # rejection (real presenter + real renderer): the Model 2 candidate fails the semantic verifier,
  # is discarded, and a deterministic reply is rendered from the packet's product_listing Evidence.
  # A deliverable means the trigger-bound job never reaches its legacy RAG fallback for this turn.
  describe 'listing semantic rejection yields a deliverable Evidence reply (no legacy fallback)' do
    def real_listing_packet
      Marine::Backend::EvidencePacketBuilder.new(clock: -> { Time.utc(2026, 9, 30, 12, 0, 0) }).build(
        evidence_input: {
          scenario: { key: 'scenario_9' }, intents: %w[product_listing], customer_language: 'id',
          response_goals: %w[answer_product_listing], validated_slots: {},
          facts: { product_listing: { products: [{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }],
                                      returned_count: 2, total_count: 2, complete: true,
                                      source: 'catalog_listing_repository', checked_at: '2026-09-30T12:00:00Z' } },
          missing_slots: [], variant_candidates: []
        }
      )
    end

    it 'delivers deterministic Evidence text (candidate discarded) rather than declining the turn' do
      packet = real_listing_packet
      allow(authority_execution).to receive(:call).and_return(
        authority_result(intents: %w[product_listing], evidence_packet: packet)
      )

      result = described_class.new(
        account: account, assistant: assistant, conversation: conversation, message: message,
        decision_runner: decision_runner, scenario_adapter: scenario_adapter,
        authority_execution: authority_execution, presenter: Marine::Backend::EvidencePacketPresenter.new,
        generator: ->(**) { 'Kami punya AAA (Alpha) dan BBB (Bravo), plus produk istimewa lainnya.' },
        fact_verifier: ->(**) { false }, context_builder: context_builder
      ).call

      expect(result).to be_deliverable
      expect(result.text).to include('AAA', 'Alpha', 'BBB', 'Bravo')
      expect(result.text).not_to include('produk istimewa lainnya')
    end
  end

  # Step 18 — the customer execution seam itself returns a DELIVERABLE for an exact-price candidate
  # failure (real presenter + real ExactPriceEvidenceRenderer): the Model 2 candidate fails a gate, is
  # discarded, and a deterministic reply is rendered from the packet's price Evidence. A deliverable
  # means the trigger-bound job never reaches its legacy fallback for this turn.
  describe 'exact-price candidate failure yields a deliverable Evidence reply (no legacy fallback)' do
    def real_price_packet
      Marine::Backend::EvidencePacketBuilder.new(clock: -> { Time.utc(2026, 9, 30, 12, 0, 0) }).build(
        evidence_input: {
          scenario: { key: 'scenario_5' }, intents: %w[price], customer_language: 'id', response_goals: %w[answer_price],
          validated_slots: {
            product: { code: 'BD', name: 'Synthetic family', source: 'marine_catalog' },
            variant: { code: 'BD-4', resolution_status: 'resolved', source: 'marine_catalog', attributes: {} }
          },
          facts: { price: { canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' },
                            display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' },
                            policy_version: 'price-display-v1', source: 'catalog_price_repository', checked_at: '2026-09-30T12:00:00Z' } },
          missing_slots: [], variant_candidates: []
        }
      )
    end

    def deliver_through_real_presenter(generator:, fact_verifier:)
      packet = real_price_packet
      allow(authority_execution).to receive(:call).and_return(authority_result(intents: %w[price], evidence_packet: packet))
      described_class.new(
        account: account, assistant: assistant, conversation: conversation, message: message,
        decision_runner: decision_runner, scenario_adapter: scenario_adapter,
        authority_execution: authority_execution, presenter: Marine::Backend::EvidencePacketPresenter.new,
        generator: generator, fact_verifier: fact_verifier, context_builder: context_builder
      ).call
    end

    it 'delivers deterministic Evidence text on a semantic rejection (fact+persona pass, verifier invoked => false)' do
      # The candidate carries ONLY the authoritative display facts in persona, so it passes the
      # deterministic PostGenerationFactValidator and PersonaValidator; the semantic verifier is the
      # gate that actually rejects it (returns false). Its distinct phrasing must not survive.
      semantic_verifier = double('fact_verifier')
      allow(semantic_verifier).to receive(:call).and_return(false)

      result = deliver_through_real_presenter(
        generator: ->(**) { 'Untuk BD-4, harganya Rp 12.500 per yard.' },
        fact_verifier: semantic_verifier
      )

      expect(semantic_verifier).to have_received(:call).once
      expect(result).to be_deliverable
      expect(result.text).to eq('Harga BD-4 adalah Rp 12.500 per yard.')
      expect(result.text).not_to include('Untuk BD-4', 'harganya')
    end

    it 'delivers deterministic Evidence text on a generation failure (no candidate)' do
      result = deliver_through_real_presenter(generator: ->(**) {}, fact_verifier: ->(**) { true })
      expect(result).to be_deliverable
      expect(result.text).to eq('Harga BD-4 adalah Rp 12.500 per yard.')
    end
  end

  # Checkpoint B — the customer execution seam itself returns a DELIVERABLE for an answer_price_range
  # candidate failure (real presenter + real PriceRangeEvidenceRenderer): the Model 2 candidate fails a
  # gate, is discarded, and a deterministic reply is rendered from the packet's price_range Evidence. A
  # deliverable means the trigger-bound job never reaches its legacy fallback for this turn. An
  # unrenderable v3 range packet (malformed fact the renderer rejects) stays NON-deliverable, so the job
  # still reaches the legacy path.
  describe 'family price-range candidate failure yields a deliverable Evidence reply (no legacy fallback)' do
    def real_range_packet
      Marine::Backend::EvidencePacketBuilder.new(clock: -> { Time.utc(2026, 9, 30, 12, 0, 0) }).build(
        evidence_input: {
          scenario: { key: 'scenario_8' }, intents: %w[price_range], customer_language: 'id', response_goals: %w[answer_price_range],
          validated_slots: { product: { code: 'BD', name: 'Santorini', source: 'marine_catalog' } },
          facts: { price_range: { canonical: { family_code: 'BD', currency: 'IDR', min: '10000', max: '12500', uom: 'Yard' },
                                  display: { currency: 'Rp', min: '10.000', max: '12.500', uom: 'yard' },
                                  policy_version: 'price-display-v1', source: 'catalog_price_range_repository',
                                  checked_at: '2026-09-30T12:00:00Z' } },
          missing_slots: [], variant_candidates: [],
          presentation_policy: { tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code' }
        }
      )
    end

    def deliver_through_real_presenter(packet, generator:, fact_verifier:)
      allow(authority_execution).to receive(:call).and_return(
        authority_result(intents: %w[price_range], evidence_packet: packet, proposed_state_transition: price_range_transition(family_code: 'BD'))
      )
      described_class.new(
        account: account, assistant: assistant, conversation: conversation, message: message,
        decision_runner: decision_runner, scenario_adapter: scenario_adapter,
        authority_execution: authority_execution, presenter: Marine::Backend::EvidencePacketPresenter.new,
        generator: generator, fact_verifier: fact_verifier, context_builder: context_builder, policy_projector: policy_projector
      ).call
    end

    it 'delivers deterministic range Evidence text on a generation failure (no candidate)' do
      result = deliver_through_real_presenter(real_range_packet, generator: ->(**) {}, fact_verifier: ->(**) { true })

      expect(result).to be_deliverable
      expect(result.text).to eq('Untuk produk BD, harganya mulai dari Rp 10.000 sampai Rp 12.500 per yard. Mau varian yang mana?')
    end

    it 'delivers deterministic range Evidence text on a semantic rejection (candidate discarded)' do
      result = deliver_through_real_presenter(
        real_range_packet,
        generator: ->(**) { 'Untuk BD, kisaran harga Rp 10.000 sampai Rp 12.500 per yard.' },
        fact_verifier: ->(**) { false }
      )

      expect(result).to be_deliverable
      expect(result.text).to eq('Untuk produk BD, harganya mulai dari Rp 10.000 sampai Rp 12.500 per yard. Mau varian yang mana?')
      expect(result.text).not_to include('kisaran harga')
    end

    it 'stays NON-deliverable for an unrenderable v3 range packet (malformed fact the renderer rejects)' do
      unrenderable = deep_freeze(
        evidence_version: 'marine_evidence_v3', generated_at: '2026-09-30T12:00:00Z', response_goals: %w[answer_price_range],
        scenario: { key: 'scenario_8', intents: %w[price_range] },
        validated_slots: { product: { code: 'BD', name: 'Santorini', attributes: {}, source: 'marine_catalog' } },
        facts: { price_range: { canonical: { family_code: 'BD', currency: 'IDR', min: 10_000.5, max: '12500', uom: 'Yard' },
                                display: { currency: 'Rp', min: '10.000', max: '12.500', uom: 'yard' },
                                policy_version: 'price-display-v1', source: 'catalog_price_range_repository', checked_at: '2026-09-30T12:00:00Z' } },
        missing_slots: [], variant_candidates: [],
        prohibited_claims: %w[exact_stock_quantity warehouse_location delivery_date unverified_discount],
        response_constraints: { max_paragraphs: 2, role: 'marine_sales_assistant', handoff_self_reference: true },
        customer_language: 'id', presentation_policy: { tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code' }
      )

      result = deliver_through_real_presenter(unrenderable, generator: ->(**) {}, fact_verifier: ->(**) { true })

      expect(result).not_to be_deliverable
      expect(result).to have_attributes(status: :fallback, reason: :presentation_rejected)
    end
  end

  it 'folds collaborator exceptions and malformed successful presentation to closed fallback results' do
    allow(decision_runner).to receive(:call).and_raise('private provider detail')
    result = execution.call
    expect(result).to have_attributes(status: :fallback, reason: :internal_error, text: nil)
    expect(result.to_s).not_to include('private provider detail')

    allow(decision_runner).to receive(:call).and_return(candidate_plan)
    allow(presenter).to receive(:call).and_return(Struct.new(:ok?, :text).new(true, nil))
    expect(execution.call).to have_attributes(status: :fallback, reason: :presentation_rejected, text: nil)
  end
end
