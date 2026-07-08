# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Charge::ResponseGenerator do
  let(:assistant) { double('assistant', name: 'Marine Bot') }
  let(:knowledge_base) { instance_double(Marine::Cell::KnowledgeBaseService) }
  let(:generator) { described_class.new(assistant: assistant) }

  before do
    allow(Marine::Cell::KnowledgeBaseService).to receive(:new).with(assistant: assistant).and_return(knowledge_base)
  end

  it 'returns a reply payload with confidence and citation metadata when confident' do
    response = Marine::AssistantResponse.new(id: 9, question: 'Hi', answer: 'Hello!')
    result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 0.9)
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'Hi')

    expect(payload).to include(
      'response' => 'Hello!',
      'action' => 'reply',
      'agent_name' => 'Marine Bot',
      'marine_cell_response_id' => 9,
      'confidence' => 0.9,
      'source_type' => 'manual',
      'response_ids' => [9],
      'document_ids' => [],
      'fallback_reason' => nil
    )
    expect(payload['citations']).to be_an(Array)
  end

  it 'hands off using the low-confidence payload when there is no confident match' do
    result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'unknown')

    expect(payload).to include(
      'response' => 'conversation_handoff',
      'action' => 'handoff',
      'action_reason' => 'no_confident_cell_match'
    )
  end
end
