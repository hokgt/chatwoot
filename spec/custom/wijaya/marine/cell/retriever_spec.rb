# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Cell::Retriever do
  let(:assistant) { double('assistant', config: {}) }
  let(:retriever) { described_class.new(assistant: assistant) }

  describe '#retrieve' do
    it 'returns an empty result with no-match fallback when nothing is found' do
      allow(retriever).to receive(:responses).and_return([])

      result = retriever.retrieve('anything')

      expect(result).not_to be_present
      expect(result.fallback_reason).to eq(described_class::NO_MATCH_REASON)
    end

    it 'returns a confident result for a strong match' do
      response = Marine::AssistantResponse.new(id: 3, question: 'greeting', answer: 'hello there friend')
      allow(retriever).to receive(:responses).and_return([response])

      result = retriever.retrieve('greeting')

      expect(result).to be_present
      expect(result.fallback_reason).to be_nil
      expect(result.confidence).to eq(1.0)
      expect(result.matched_response_id).to eq(3)
    end

    it 'flags a low-confidence fallback when the match is weak' do
      response = Marine::AssistantResponse.new(id: 4, question: 'greeting', answer: 'hello there friend')
      allow(retriever).to receive(:responses).and_return([response])

      result = retriever.retrieve('zzz totally unrelated query')

      expect(result).to be_present
      expect(result.fallback_reason).to eq(described_class::LOW_CONFIDENCE_REASON)
    end
  end
end
