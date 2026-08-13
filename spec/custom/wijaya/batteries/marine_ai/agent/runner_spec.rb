# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Agent::Runner do
  let(:assistant) { double('assistant', id: 1, name: 'Marine Bot', account: nil) }
  let(:generator) { instance_double(Marine::Charge::ResponseGenerator) }
  let(:selector) { instance_double(Marine::Agent::ScenarioSelector) }
  let(:runner) { described_class.new(assistant: assistant) }

  def reply_payload(overrides = {})
    {
      'response' => 'Your order is on the way',
      'action' => 'reply',
      'agent_name' => 'Marine Bot',
      'marine_cell_response_id' => 9,
      'confidence' => 0.9,
      'citations' => [{ response_id: 9, question: 'Where is my order', source_type: 'manual' }],
      'source_type' => 'manual',
      'response_ids' => [9],
      'document_ids' => [],
      'fallback_reason' => nil,
      'detected_language' => 'en',
      'translation_applied' => false
    }.merge(overrides)
  end

  def handoff_payload(overrides = {})
    {
      'response' => 'conversation_handoff',
      'action' => 'handoff',
      'action_source' => 'marine_circuit',
      'action_reason' => 'no_confident_cell_match',
      'detected_language' => 'en',
      'translation_applied' => false
    }.merge(overrides)
  end

  before do
    allow(Marine::Charge::ResponseGenerator).to receive(:new).and_return(generator)
    allow(Marine::Agent::ScenarioSelector).to receive(:new).and_return(selector)
    allow(selector).to receive(:select).and_return(nil)
  end

  describe 'default retrieval path' do
    it 'returns the retrieval reply enriched with orchestration metadata' do
      allow(generator).to receive(:generate).and_return(reply_payload)

      payload = runner.run(additional_message: 'Where is my order')

      expect(payload).to include(
        'response' => 'Your order is on the way',
        'action' => 'reply',
        'confidence' => 0.9,
        'source_type' => 'manual',
        'orchestration_path' => 'retrieval',
        'marine_scenario_id' => nil,
        'marine_scenario_tools' => []
      )
      expect(payload['citations']).to be_an(Array)
    end
  end

  describe 'scenario selection path' do
    let(:scenario) { double('scenario', id: 7, title: 'Order status', resolved_tools: []) }

    it 'marks the path as scenario_retrieval when a scenario matches' do
      allow(selector).to receive(:select).with('Where is my order').and_return(scenario)
      allow(generator).to receive(:generate).and_return(reply_payload)

      payload = runner.run(additional_message: 'Where is my order')

      expect(payload).to include(
        'orchestration_path' => 'scenario_retrieval',
        'marine_scenario_id' => 7,
        'marine_scenario_title' => 'Order status',
        'marine_scenario_tools' => []
      )
    end
  end

  # Custom HTTP tools have been removed to eliminate all direct outbound
  # connectivity between Marine AI and ERP; the runner never resolves tool slugs
  # and marine_scenario_tools stays an empty array.
  describe 'tool reference resolution path (disabled)' do
    let(:account) { create(:account) }
    let(:db_assistant) { create(:marine_assistant, account: account) }
    let(:runner) { described_class.new(assistant: db_assistant) }

    before do
      allow(Marine::Agent::ScenarioSelector).to receive(:new).and_call_original
      allow(generator).to receive(:generate).and_return(reply_payload)
    end

    it 'never resolves tool slugs and exposes no auth secrets' do
      create(:marine_custom_tool, account: account, slug: 'custom_fetch-order', title: 'Fetch Order',
                                  description: 'Gets order details', auth_type: 'bearer',
                                  auth_config: { 'token' => 'super-secret-token' })
      create(:marine_scenario, assistant: db_assistant, account: account,
                               title: 'Order status', description: 'Track a delivery order shipment',
                               instruction: 'Track the order shipment using [@Fetch Order](tool://custom_fetch-order)')

      payload = runner.run(additional_message: 'track my order shipment delivery')

      expect(payload['marine_scenario_tools']).to eq([])
      expect(payload.to_s).not_to include('super-secret-token')
      expect(payload.to_s).not_to include('auth_config')
    end
  end

  describe 'multilingual fallback behavior' do
    it 'preserves translation metadata produced by the retrieval generator' do
      allow(generator).to receive(:generate).and_return(
        reply_payload('detected_language' => 'id', 'query_language' => 'id',
                      'translation_applied' => true, 'response_translation_applied' => true)
      )

      payload = runner.run(additional_message: 'Pesanan saya di mana')

      expect(payload).to include(
        'detected_language' => 'id',
        'query_language' => 'id',
        'translation_applied' => true,
        'response_translation_applied' => true,
        'orchestration_path' => 'retrieval'
      )
    end
  end

  describe 'low confidence / no result handoff path' do
    it 'returns the handoff payload with the retrieval fallback reason' do
      allow(generator).to receive(:generate).and_return(handoff_payload)

      payload = runner.run(additional_message: 'unknown question')

      expect(payload).to include(
        'response' => 'conversation_handoff',
        'action' => 'handoff',
        'action_reason' => 'no_confident_cell_match',
        'orchestration_path' => 'handoff'
      )
    end
  end

  describe 'safety when orchestration fails' do
    it 'never raises and degrades to a handoff payload with a runner_error reason' do
      allow(generator).to receive(:generate).and_raise(StandardError, 'boom')

      payload = runner.run(additional_message: 'Where is my order')

      expect(payload).to include(
        'response' => 'conversation_handoff',
        'action' => 'handoff',
        'action_reason' => 'runner_error',
        'orchestration_path' => 'handoff'
      )
    end
  end

  describe 'product path (Phase 5)' do
    let(:account) { build_stubbed(:account) }
    let(:conversation) { build_stubbed(:conversation, account: account) }
    let(:message) { build_stubbed(:message, conversation: conversation, message_type: :incoming, content: 'price for impeller 3 inch') }
    let(:runner) { described_class.new(assistant: assistant, conversation: conversation, source: message) }
    let(:orchestrator) { instance_double(Marine::Catalog::ProductQueryOrchestrator) }

    before do
      allow(Marine::Catalog::ProductQueryOrchestrator).to receive(:new).and_return(orchestrator)
    end

    it 'runs the orchestrator before RAG and returns the product plan payload' do
      plan = { action: :reply, reply: { kind: :price_available }, state: { operation: :update, changes: {} } }
      allow(orchestrator).to receive(:process).and_return(plan)
      allow(generator).to receive(:generate)

      payload = runner.run(additional_message: 'price for impeller 3 inch')

      expect(payload).to eq('action' => 'product', 'orchestration_path' => 'product', 'product_plan' => plan)
      expect(generator).not_to have_received(:generate)
    end

    it 'passes the exact incoming message content and the current flow snapshot to the orchestrator' do
      allow(orchestrator).to receive(:process).and_return(action: :not_product, reply: nil, state: { operation: :none, changes: {} })
      allow(generator).to receive(:generate).and_return(reply_payload)

      runner.run(additional_message: 'ignored — text comes from the trigger message')

      expect(orchestrator).to have_received(:process).with(hash_including(text: 'price for impeller 3 inch', suppressed: false))
    end

    it 'falls through to the unchanged retrieval path on a not_product plan' do
      allow(orchestrator).to receive(:process).and_return(action: :not_product, reply: nil, state: { operation: :none, changes: {} })
      allow(generator).to receive(:generate).and_return(reply_payload)

      payload = runner.run(additional_message: 'just saying hello')

      expect(payload).to include('response' => 'Your order is on the way', 'orchestration_path' => 'retrieval')
    end
  end

  describe 'independence from Captain premium gates' do
    it 'does not reference any Captain runtime dependency in the source' do
      source = File.read(Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/agent/runner.rb'))
      captain_dependency = Regexp.union('Captain::', 'ChatwootHub', 'hub.2.chatwoot.com', 'pricing_plan',
                                        'CAPTAIN_CLOUD_PLAN_LIMITS', 'FEATURE_FLAGS.CAPTAIN', 'captain_integration')
      expect(source).not_to match(captain_dependency)
    end
  end
end
