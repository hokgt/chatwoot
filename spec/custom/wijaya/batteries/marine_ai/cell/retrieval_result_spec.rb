# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Cell::RetrievalResult do
  let(:response) { Marine::AssistantResponse.new(id: 5, question: 'Hi', answer: 'Hello there') }

  describe '.empty' do
    it 'produces an absent result with a fallback reason' do
      result = described_class.empty(fallback_reason: 'no_confident_cell_match')

      expect(result).not_to be_present
      expect(result.confidence).to eq(0.0)
      expect(result.citations).to eq([])
      expect(result.response_ids).to eq([])
      expect(result.document_ids).to eq([])
      expect(result.fallback_reason).to eq('no_confident_cell_match')
    end
  end

  describe '#to_metadata' do
    it 'exposes JSON-safe confidence and citation metadata' do
      result = described_class.new(responses: [response], confidence: 1.4)

      expect(result.confidence).to eq(1.0)
      expect(result).to be_present
      expect(result.answer).to eq('Hello there')
      expect(result.matched_response_id).to eq(5)
      expect(result.source_type).to eq('manual')
      expect(result.response_ids).to eq([5])
      expect(result.to_metadata.keys).to contain_exactly(
        :confidence, :citations, :source_type, :response_ids, :document_ids, :fallback_reason
      )
    end
  end

  describe '#confident?' do
    it 'is true only when present and above threshold' do
      result = described_class.new(responses: [response], confidence: 0.5)

      expect(result.confident?(0.4)).to be(true)
      expect(result.confident?(0.6)).to be(false)
      expect(described_class.empty(fallback_reason: 'x').confident?(0.0)).to be(false)
    end
  end
end
