# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 4 — the SHADOW-ONLY comparison harness. These examples drive it with
# record doubles + stubbed collaborators and pin: the four records must genuinely belong
# together and the message be a public incoming turn (else nil); it calls the legacy
# ScenarioSelector and the Decision Runner on the SAME canonical trigger/scenarios; it
# returns a small deep-frozen { legacy_scenario_key, candidate_plan }; and — by source scan —
# it performs NO write/reply/routing/state mutation. All strings are SYNTHETIC.
RSpec.describe Marine::Decision::ShadowExecution do
  subject(:execution) do
    described_class.new(account: account, assistant: assistant, conversation: conversation, message: message,
                        classification_intents: classification)
  end

  let(:classification) { %w[price unsupported] }
  let(:account) { double('account', id: 1) }
  let(:assistant) { double('assistant', id: 3, account_id: 1) }
  let(:inbox) { double('inbox', marine_assistant: assistant) }
  let(:conversation) { double('conversation', id: 5, account_id: 1, inbox: inbox) }
  let(:message) { double('message', conversation_id: 5, incoming?: true, private?: false) }

  let(:context) { double('context', trigger: 'Do you have the vase in stock?', history: []) }
  let(:plan) { { schema_version: 'marine_decision_v1', reason: 'normalized' }.freeze }

  before do
    context_builder = instance_double(Marine::Conversation::ContextBuilder, build: context)
    allow(Marine::Conversation::ContextBuilder).to receive(:new)
      .with(conversation: conversation, trigger_message: message).and_return(context_builder)

    adapter = instance_double(Marine::Decision::ScenarioAdapter, scenarios: [], overflow?: false)
    allow(Marine::Decision::ScenarioAdapter).to receive(:new).with(assistant: assistant).and_return(adapter)

    selector = instance_double(Marine::Agent::ScenarioSelector, select: double('scenario', id: 42))
    allow(Marine::Agent::ScenarioSelector).to receive(:new).with(assistant: assistant).and_return(selector)

    runner = instance_double(Marine::Decision::Runner, call: plan)
    allow(Marine::Decision::Runner).to receive(:new).and_return(runner)
  end

  describe 'valid turn' do
    it 'returns a deep-frozen legacy key + candidate plan computed on the same trigger' do
      selector = instance_double(Marine::Agent::ScenarioSelector)
      allow(Marine::Agent::ScenarioSelector).to receive(:new).and_return(selector)
      expect(selector).to receive(:select).with('Do you have the vase in stock?').and_return(double('scenario', id: 42))

      runner = instance_double(Marine::Decision::Runner)
      expect(Marine::Decision::Runner).to receive(:new).with(classification_intents: %w[price unsupported]).and_return(runner)
      expect(runner).to receive(:call)
        .with(message: 'Do you have the vase in stock?', scenarios: [], context: []).and_return(plan)

      result = execution.call
      expect(result).to eq(legacy_scenario_key: 'scenario_42', candidate_plan: plan)
      expect(result).to be_frozen
      expect(result[:legacy_scenario_key]).to be_frozen
    end

    it 'carries a nil legacy key when the selector matches nothing' do
      selector = instance_double(Marine::Agent::ScenarioSelector, select: nil)
      allow(Marine::Agent::ScenarioSelector).to receive(:new).and_return(selector)
      expect(execution.call[:legacy_scenario_key]).to be_nil
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

    it 'does not invoke the runner when validation fails' do
      allow(message).to receive(:incoming?).and_return(false)
      expect(Marine::Decision::Runner).not_to receive(:new)
      execution.call
    end
  end

  describe 'injected classification vocabulary (fail closed to nil)' do
    it 'returns nil and NEVER runs the Decision Runner for a nil / empty / non-Array / non-String vocabulary' do
      expect(Marine::Decision::Runner).not_to receive(:new)
      [nil, [], 'price', [1]].each do |bad|
        exec = described_class.new(account: account, assistant: assistant, conversation: conversation,
                                   message: message, classification_intents: bad)
        expect(exec.call).to be_nil
      end
    end
  end

  describe 'scenario overflow (fail closed to nil)' do
    before do
      overflowing = instance_double(Marine::Decision::ScenarioAdapter, overflow?: true)
      allow(Marine::Decision::ScenarioAdapter).to receive(:new).with(assistant: assistant).and_return(overflowing)
    end

    it 'returns nil without building context, selecting, or running the Decision Runner' do
      expect(Marine::Conversation::ContextBuilder).not_to receive(:new)
      expect(Marine::Agent::ScenarioSelector).not_to receive(:new)
      expect(Marine::Decision::Runner).not_to receive(:new)

      expect(execution.call).to be_nil
    end
  end

  describe 'isolation / no side effects (source proof)' do
    it 'performs no write/reply/routing/state-mutation call in CODE' do
      dir = Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/decision')
      code = %w[shadow_execution scenario_adapter shadow_config]
             .map { |name| File.read(dir.join("#{name}.rb")).gsub(/#(?!\{).*/, '') }.join("\n")

      forbidden = ['.create', '.create!', '.save', '.update!', '.update(', 'HandoffService',
                   'ProductFlowStateStore', 'perform_later', 'perform_now', 'deliver', 'Agent::Runner.new']
      forbidden.each { |token| expect(code).not_to include(token) }
    end
  end
end
