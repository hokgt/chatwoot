# frozen_string_literal: true

require 'rails_helper'

# Phase 2A — the read-only AuthorityShadowExecution hook. Every collaborator (ContextBuilder,
# ScenarioResolver, ShadowConfig, ProductFlowStateStore, AuthorityCoordinator) is stubbed so no
# provider/Runner/DB/Redis is touched. These examples pin: it REUSES the supplied candidate_plan and
# NEVER runs the Decision Runner / a second provider call, validates the scoped relationship +
# public-incoming turn, accepts only a canonical medium/high plan, re-resolves the scenario to an
# enabled row, reads the flow snapshot read-only, and returns ONLY the coordinator's bounded Result.
RSpec.describe Marine::Backend::AuthorityShadowExecution do
  let(:account) { double('account', id: 1) }
  let(:assistant) { double('assistant', id: 3, account_id: 1, config: double('config', to_h: { 'language' => 'id' })) }
  let(:inbox) { double('inbox', present?: true, marine_assistant: assistant) }
  let(:conversation) { double('conversation', id: 5, account_id: 1, inbox: inbox) }
  let(:message) { double('message', id: 9, conversation_id: 5, incoming?: true, private?: false) }

  let(:scenario) { double('scenario', id: 3) }
  let(:context) { double('context', trigger: 'berapa harga', history: [], phase: :opening) }
  let(:context_builder) { instance_double(Marine::Conversation::ContextBuilder, build: context) }
  let(:flow_store) { instance_double(Marine::Catalog::ProductFlowStateStore, current_for_planning: nil) }
  let(:coordinator) { instance_double(Marine::Backend::AuthorityCoordinator) }
  let(:coordinator_result) { double('result') }

  let(:candidate_plan) do
    Marine::Decision::CandidatePlan.normalize(
      'schema_version' => 'marine_decision_v1',
      'scenario_candidate' => { 'key' => 'scenario_3', 'confidence' => 'high' },
      'intents' => %w[price], 'slot_operations' => [], 'customer_language' => nil, 'confidence' => 'high'
    )
  end

  def execution(plan: candidate_plan)
    described_class.new(account: account, assistant: assistant, conversation: conversation, message: message, candidate_plan: plan)
  end

  before do
    allow(Marine::Conversation::ContextBuilder).to receive(:new).and_return(context_builder)
    allow(Marine::Decision::ScenarioResolver).to receive(:resolve).and_return(scenario)
    allow(Marine::Catalog::ProductFlowStateStore).to receive(:new).and_return(flow_store)
    allow(Marine::Backend::AuthorityCoordinator).to receive(:new).and_return(coordinator)
    allow(coordinator).to receive(:call).and_return(coordinator_result)
  end

  describe 'the happy path' do
    it 'reuses the supplied plan through the coordinator and returns its bounded Result' do
      expect(coordinator).to receive(:call).with(
        candidate_plan: candidate_plan, scenario_key: 'scenario_3',
        trigger: 'berapa harga', history: [], phase: :opening, flow_state: nil, configured_language: 'id'
      ).and_return(coordinator_result)

      expect(execution.call).to equal(coordinator_result)
    end

    it 'NEVER instantiates the Decision Runner or a second shadow execution (no second provider call)' do
      expect(Marine::Decision::Runner).not_to receive(:new)
      expect(Marine::Decision::ShadowExecution).not_to receive(:new)

      execution.call
    end

    it 'reads the flow snapshot read-only (current_for_planning only)' do
      expect(flow_store).to receive(:current_for_planning).and_return(nil)
      expect(flow_store).not_to receive(:start!)
      expect(flow_store).not_to receive(:update!)

      execution.call
    end

    it 're-resolves the scenario key to an ENABLED scenario for this assistant' do
      expect(Marine::Decision::ScenarioResolver).to receive(:resolve).with(assistant: assistant, key: 'scenario_3').and_return(scenario)

      execution.call
    end
  end

  describe 'relationship validation (fail closed, no work)' do
    it 'returns nil for a mismatched linked assistant and never calls the coordinator' do
      allow(inbox).to receive(:marine_assistant).and_return(double('other', id: 99))
      expect(Marine::Backend::AuthorityCoordinator).not_to receive(:new)

      expect(execution.call).to be_nil
    end

    it 'returns nil for a private message' do
      allow(message).to receive(:private?).and_return(true)
      expect(execution.call).to be_nil
    end

    it 'returns nil for an outgoing message' do
      allow(message).to receive(:incoming?).and_return(false)
      expect(execution.call).to be_nil
    end

    it 'returns nil for a cross-account conversation' do
      allow(conversation).to receive(:account_id).and_return(999)
      expect(execution.call).to be_nil
    end
  end

  describe 'plan acceptance (medium/high, canonical-normalized)' do
    it 'stops (unsupported_plan) for a low overall confidence plan without resolving the scenario' do
      plan = Marine::Decision::CandidatePlan.normalize(
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_3', 'confidence' => 'high' },
        'intents' => %w[price], 'slot_operations' => [], 'customer_language' => nil, 'confidence' => 'low'
      )
      expect(Marine::Decision::ScenarioResolver).not_to receive(:resolve)

      result = execution(plan: plan).call

      expect(result.outcome_type).to eq(:stop)
      expect(result.reason).to eq(:unsupported_plan)
    end

    it 'stops (unsupported_plan) for a low scenario_candidate confidence' do
      plan = Marine::Decision::CandidatePlan.normalize(
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_3', 'confidence' => 'low' },
        'intents' => %w[price], 'slot_operations' => [], 'customer_language' => nil, 'confidence' => 'high'
      )

      expect(execution(plan: plan).call.reason).to eq(:unsupported_plan)
    end

    it 'stops (unsupported_plan) for a non-canonical (unknown-reason) plan' do
      expect(execution(plan: Marine::Decision::CandidatePlan.unknown('timeout')).call.reason).to eq(:unsupported_plan)
    end
  end

  describe 'scenario resolution' do
    it 'stops (scenario_mismatch) when the key does not re-resolve to an enabled scenario' do
      allow(Marine::Decision::ScenarioResolver).to receive(:resolve).and_return(nil)
      expect(Marine::Backend::AuthorityCoordinator).not_to receive(:new)

      result = execution.call

      expect(result.outcome_type).to eq(:stop)
      expect(result.reason).to eq(:scenario_mismatch)
    end
  end
end
