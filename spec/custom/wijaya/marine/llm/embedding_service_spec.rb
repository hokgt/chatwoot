# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::EmbeddingService do
  subject(:service) { described_class.new(account_id: nil) }

  it 'returns nil for blank text' do
    expect(service.get_embedding('')).to be_nil
  end

  it 'returns nil (no remote call) when Marine LLM is not configured' do
    allow(Marine::Llm::Config).to receive(:configured?).and_return(false)
    expect(RubyLLM).not_to receive(:context)

    expect(service.get_embedding('some text')).to be_nil
  end

  it 'returns the embedding vector when configured' do
    allow(Marine::Llm::Config).to receive(:configured?).and_return(true)
    embedding = instance_double(RubyLLM::Embedding, vectors: [0.1, 0.2])
    context = instance_double(RubyLLM::Context)
    allow(service).to receive(:context).and_return(context)
    allow(context).to receive(:embed).and_return(embedding)

    expect(service.get_embedding('some text')).to eq([0.1, 0.2])
  end

  it 'degrades to nil when the provider raises' do
    allow(Marine::Llm::Config).to receive(:configured?).and_return(true)
    context = instance_double(RubyLLM::Context)
    allow(service).to receive(:context).and_return(context)
    allow(context).to receive(:embed).and_raise(StandardError, 'boom')

    expect(service.get_embedding('some text')).to be_nil
  end
end
