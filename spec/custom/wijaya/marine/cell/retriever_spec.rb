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

  describe '#score' do
    let(:query_tokens) { retriever.send(:tokenize, 'what is textilindo email') }

    it 'weights answer-field overlap above question-field overlap' do
      answer_match = Marine::AssistantResponse.new(question: 'Textilindo Contact', answer: 'Our email is sales@textilindo.com')
      question_only = Marine::AssistantResponse.new(question: 'Textilindo email hours', answer: 'We are open 9-5')

      answer_score = retriever.send(:score, answer_match, query_tokens)
      question_score = retriever.send(:score, question_only, query_tokens)

      expect(answer_score).to be > question_score
    end

    it 'boosts document-backed responses' do
      manual = Marine::AssistantResponse.new(question: 'Textilindo Contact', answer: 'email textilindo info')
      document = Marine::AssistantResponse.new(question: 'Textilindo Contact', answer: 'email textilindo info', documentable_type: 'Marine::Document')

      expect(retriever.send(:score, document, query_tokens)).to be > retriever.send(:score, manual, query_tokens)
    end
  end
end
