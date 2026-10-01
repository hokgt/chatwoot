# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the SHADOW-ONLY, side-effect-free PRODUCT-authority comparison harness. These examples
# inject ALL seams (no provider/DB/Redis runs) and pin: the four records must genuinely belong
# together and the message be a public incoming turn (else nil); a scenario overflow fails closed to
# nil BEFORE any extractor/runner work; the legacy IntentExtractor is run STATELESS (state: nil); the
# candidate side folds the Decision Runner's plan through the Fase 3A-1 adapter, is comparable ONLY
# when the plan genuinely normalized, and projects to ProductOutcome.blocked when the adapter fails
# closed; and — by source scan — it is adapter-only (never ProductExecutionPlanner) and touches no
# persistence. All strings are SYNTHETIC.
RSpec.describe Marine::ProductAuthority::ShadowExecution do
  subject(:execution) do
    described_class.new(
      account: double('account', id: 1), assistant: assistant, conversation: conversation, message: message,
      intent_extractor: intent_extractor, decision_runner: decision_runner, adapter: adapter,
      scenario_selector: double('scenario_selector', select: double('scenario', id: 1)),
      scenario_adapter: scenario_adapter,
      context_builder: double('context_builder', call: double('context', trigger: trigger, history: []))
    )
  end

  let(:assistant) { double('assistant', id: 3, account_id: 1) }
  let(:inbox) { double('inbox', marine_assistant: assistant) }
  let(:conversation) { double('conversation', id: 5, account_id: 1, inbox: inbox) }
  let(:message) { double('message', conversation_id: 5, incoming?: true, private?: false) }

  let(:trigger) { 'SYN do you have the alpha vase in stock?' }

  let(:scenarios) { [{ 'key' => 'scenario_1', 'capabilities' => %w[price stock] }] }
  let(:scenario_adapter) { double('scenario_adapter', overflow?: false, scenarios: scenarios) }

  # A legacy IntentExtractor-shaped product-intent hash (SYNTHETIC candidates only).
  let(:legacy_product_intent) do
    {
      product_related: true, intent: 'price', requested_intents: ['price'],
      requires_exact_variant: true, quantity_inquiry: false,
      family_mention: 'SYN-FAM-ALPHA', explicit_child_code: 'SYN-VAR-ALPHA-01', attribute_candidates: []
    }
  end

  # The adapter's candidate product-intent (same shape) so its projection is deterministic.
  let(:candidate_product_intent) do
    {
      product_related: true, intent: 'price', requested_intents: ['price'],
      requires_exact_variant: true, quantity_inquiry: false,
      family_mention: 'SYN-FAM-ALPHA', explicit_child_code: 'SYN-VAR-ALPHA-01', attribute_candidates: []
    }
  end

  let(:adapter_result) do
    double('adapter_result', ok?: true, product_intent: candidate_product_intent,
                             intents: ['price'], scenario: { key: 'scenario_1', capabilities: %w[price stock] }, reason: 'accepted')
  end

  let(:intent_extractor) { double('intent_extractor') }
  let(:decision_runner) { double('decision_runner') }
  let(:adapter) { double('adapter') }

  before do
    plan = { schema_version: 'marine_decision_v1', reason: 'normalized' }
    capability_map = { 'scenario_1' => %w[price stock] }
    allow(intent_extractor).to receive(:extract)
      .with(text: trigger, context: [], state: nil).and_return(legacy_product_intent)
    allow(decision_runner).to receive(:call)
      .with(message: trigger, scenarios: scenarios, context: []).and_return(plan)
    allow(adapter).to receive(:call)
      .with(plan: plan, scenario_key: 'scenario_1', scenario_capabilities: capability_map).and_return(adapter_result)
  end

  describe 'happy path (valid public incoming turn)' do
    it 'projects both legacy and candidate outcomes and reports comparable when the plan normalized' do
      result = execution.call

      expect(result[:legacy]).to eq(Marine::ProductAuthority::ProductOutcome.project(legacy_product_intent))
      expect(result[:candidate]).to eq(Marine::ProductAuthority::ProductOutcome.project(candidate_product_intent))
      expect(result[:comparable]).to be(true)
      expect(result.keys).to contain_exactly(:legacy, :candidate, :comparable)
    end

    it 'returns a deep-frozen result whose members are frozen' do
      result = execution.call
      expect(result).to be_frozen
      expect(result[:legacy]).to be_frozen
      expect(result[:candidate]).to be_frozen
    end

    it 'runs the legacy extractor STATELESS (state: nil)' do
      expect(intent_extractor).to receive(:extract).with(text: trigger, context: [], state: nil).and_return(legacy_product_intent)
      execution.call
    end

    it 'is NOT comparable when the decision plan is a non-normalized fallback' do
      allow(decision_runner).to receive(:call).and_return(schema_version: 'marine_decision_v1', reason: 'timeout')
      expect(execution.call[:comparable]).to be(false)
    end

    it 'projects the candidate to ProductOutcome.blocked when the adapter fails closed' do
      allow(adapter_result).to receive(:ok?).and_return(false)
      result = execution.call
      expect(result[:candidate]).to eq(Marine::ProductAuthority::ProductOutcome.blocked)
      expect(result[:candidate][:status]).to eq(Marine::ProductAuthority::ProductOutcome::STATUS_BLOCKED)
    end
  end

  describe 'relationship + eligibility validation (fail closed to nil)' do
    it 'rejects a message that belongs to another conversation' do
      allow(message).to receive(:conversation_id).and_return(999)
      expect(execution.call).to be_nil
    end

    it 'rejects a conversation in another account' do
      allow(conversation).to receive(:account_id).and_return(999)
      expect(execution.call).to be_nil
    end

    it 'rejects an assistant in another account' do
      allow(assistant).to receive(:account_id).and_return(999)
      expect(execution.call).to be_nil
    end

    it 'rejects an inbox linked to a different marine assistant' do
      allow(inbox).to receive(:marine_assistant).and_return(double('other', id: 77))
      expect(execution.call).to be_nil
    end

    it 'rejects a private message' do
      allow(message).to receive(:private?).and_return(true)
      expect(execution.call).to be_nil
    end

    it 'rejects an outgoing message' do
      allow(message).to receive(:incoming?).and_return(false)
      expect(execution.call).to be_nil
    end
  end

  describe 'scenario overflow (fail closed to nil, before any comparison work)' do
    before { allow(scenario_adapter).to receive(:overflow?).and_return(true) }

    it 'returns nil without running the extractor or the decision runner' do
      expect(intent_extractor).not_to receive(:extract)
      expect(decision_runner).not_to receive(:call)
      expect(adapter).not_to receive(:call)

      expect(execution.call).to be_nil
    end
  end

  describe 'isolation / adapter-only, no side effects (source proof)' do
    let(:source) do
      Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/shadow_execution.rb').read
    end

    it 'references the Fase 3A-1 adapter and the legacy IntentExtractor' do
      expect(source).to include('Marine::Backend::CandidatePlanToProductIntentAdapter')
      expect(source).to include('Marine::Catalog::IntentExtractor')
    end

    it 'is adapter-only: never the catalog-DB ProductExecutionPlanner' do
      expect(source).not_to include('ProductExecutionPlanner')
    end

    it 'performs no persistence call' do
      code = source.gsub(/#(?!\{).*/, '')
      ['.create!', '.update!', '.save!', 'with_lock'].each { |token| expect(code).not_to include(token) }
    end
  end
end
