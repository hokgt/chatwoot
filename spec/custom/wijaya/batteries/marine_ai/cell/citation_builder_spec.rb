# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Cell::CitationBuilder do
  it 'builds a manual citation without document fields' do
    response = Marine::AssistantResponse.new(id: 1, question: 'Q1', answer: 'A1')

    citation = described_class.build([response]).first

    expect(citation).to eq(response_id: 1, question: 'Q1', source_type: 'manual')
  end

  it 'includes only safe document metadata for Marine::Document sources' do
    document = Marine::Document.new(id: 7, name: 'Policy', external_link: 'https://example.com/policy')
    response = Marine::AssistantResponse.new(id: 2, question: 'Q2', answer: 'A2', documentable: document)

    citation = described_class.build([response]).first

    expect(citation).to include(
      response_id: 2,
      question: 'Q2',
      source_type: 'document',
      document_id: 7,
      document_name: 'Policy',
      external_link: 'https://example.com/policy'
    )
    expect(citation.keys).not_to include(:embedding)
  end

  it 'skips nil records' do
    expect(described_class.build([nil])).to eq([])
  end
end
