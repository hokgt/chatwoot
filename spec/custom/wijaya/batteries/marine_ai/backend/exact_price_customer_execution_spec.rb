# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Backend::ExactPriceCustomerExecution do
  Coordinator = Marine::Backend::AuthorityCoordinator

  subject(:execution) do
    described_class.new(
      account: account, assistant: assistant, conversation: conversation, message: message,
      decision_runner: decision_runner, scenario_adapter: scenario_adapter,
      authority_execution: authority_execution, presenter: presenter, generator: generator,
      fact_verifier: fact_verifier, context_builder: context_builder
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

  def packet(version: 'marine_evidence_v2', goals: %w[answer_price], facts: { price: { display: 'safe' } })
    deep_freeze(evidence_version: version, response_goals: goals, facts: facts)
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
    expect(authority_execution).to receive(:call).once.with(candidate_plan: candidate_plan).and_return(accepted)
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
      authority_result(intents: %w[stock]),
      authority_result(intents: %w[price stock]),
      authority_result(outcome: Coordinator::OUTCOME_LEGACY_PRESERVED,
                       reason: Coordinator::REASON_CANDIDATE_CONTEXT_INSUFFICIENT),
      authority_result(outcome: Coordinator::OUTCOME_CLARIFY, reason: Coordinator::REASON_VARIANT_AMBIGUOUS),
      authority_result(outcome: Coordinator::OUTCOME_HANDOFF, reason: Coordinator::REASON_PRICE_UNAVAILABLE),
      Object.new,
      authority_result(evidence_packet: packet(version: 'marine_evidence_v1')),
      authority_result(evidence_packet: packet(goals: %w[answer_price handoff])),
      authority_result(evidence_packet: packet(facts: { price: {}, stock: {} }))
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
