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

  def authority_result(outcome: Coordinator::OUTCOME_EVIDENCE_PACKET,
                       reason: Coordinator::REASON_ACCEPTED, intents: %w[price], evidence_packet: packet)
    Coordinator::Result.new(
      outcome_type: outcome, reason: reason, scenario_key: 'scenario_5',
      intents: deep_freeze(intents), source: :catalog, evidence_packet: evidence_packet
    ).freeze
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
    evidence = packet
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
    expect(result.to_h.keys).to eq(%i[status reason text])
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
      expect(result.to_h.keys).to eq(%i[status reason text])
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

  describe 'Phase 5 — the same single attempt delivers an exact-shape price_range / stock target' do
    it 'delivers a price_range target only for the exact v3 answer_price_range => [:price_range] shape with a valid policy' do
      accepted = authority_result(intents: %w[price_range],
                                  evidence_packet: packet(version: 'marine_evidence_v3', goals: %w[answer_price_range],
                                                          facts: { price_range: { display: 'r' } }, presentation_policy: presentation_policy))
      allow(authority_execution).to receive(:call).and_return(accepted)
      allow(presenter).to receive(:call).and_return(Struct.new(:ok?, :text, :reason).new(true, 'Kisaran harga BD: Rp 10.000–12.500 per yard.',
                                                                                         :accepted))

      result = execution.call
      expect(result).to be_deliverable
      expect(result.text).to eq('Kisaran harga BD: Rp 10.000–12.500 per yard.')
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
          validated_slots: { variant: { code: 'BD-4', resolution_status: 'resolved', source: 'marine_catalog', attributes: {} } },
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
