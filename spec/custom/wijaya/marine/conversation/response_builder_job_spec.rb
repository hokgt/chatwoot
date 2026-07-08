# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Conversation::ResponseBuilderJob do
  describe '#create_marine_reply' do
    let(:assistant) { double('assistant') }
    let(:messages) { double('messages') }
    let(:conversation) { double('conversation', account_id: 11, inbox_id: 22, messages: messages) }
    let(:job) { described_class.new }

    it 'persists confidence and citation metadata alongside legacy attributes' do
      job.instance_variable_set(:@conversation, conversation)
      job.instance_variable_set(:@assistant, assistant)
      job.instance_variable_set(:@response, {
                                  'response' => 'Hello!',
                                  'agent_name' => 'Marine Bot',
                                  'marine_cell_response_id' => 9,
                                  'confidence' => 0.9,
                                  'citations' => [{ response_id: 9, question: 'Hi', source_type: 'manual' }],
                                  'source_type' => 'manual',
                                  'response_ids' => [9],
                                  'document_ids' => [],
                                  'fallback_reason' => nil
                                })

      expect(messages).to receive(:create!).with(
        hash_including(
          additional_attributes: {
            agent_name: 'Marine Bot',
            marine_cell_response_id: 9,
            confidence: 0.9,
            citations: [{ response_id: 9, question: 'Hi', source_type: 'manual' }],
            source_type: 'manual',
            response_ids: [9],
            document_ids: []
          }
        )
      )

      job.send(:create_marine_reply)
    end
  end
end
