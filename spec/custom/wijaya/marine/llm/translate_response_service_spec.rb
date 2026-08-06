# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::TranslateResponseService do
  let(:base_service) { instance_double(Marine::Llm::BaseService) }

  before do
    allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
  end

  it 'is a no-op when the target language matches the source language' do
    expect(base_service).not_to receive(:complete)

    result = described_class.new(text: 'Hello there', source_language: 'en', target_language: 'en').call

    expect(result).to include(translated: false, text: 'Hello there', error: nil)
    expect(result[:skipped_reason]).to eq('same_language')
  end

  it 'degrades safely when the target language is unknown' do
    expect(base_service).not_to receive(:complete)

    result = described_class.new(text: 'Hello there', source_language: 'en', target_language: 'unknown').call

    expect(result).to include(translated: false, text: 'Hello there', error: nil)
    expect(result[:skipped_reason]).to eq('unknown_target_language')
  end

  it 'degrades safely for blank input' do
    result = described_class.new(text: '   ', source_language: 'en', target_language: 'id').call

    expect(result).to include(translated: false, error: nil)
    expect(result[:skipped_reason]).to eq('blank_input')
  end

  it 'does not call the provider when Marine LLM is not configured' do
    allow(base_service).to receive(:configured?).and_return(false)
    expect(base_service).not_to receive(:complete)

    result = described_class.new(text: 'Hello there', source_language: 'en', target_language: 'id').call

    expect(result).to include(translated: false, text: 'Hello there', source_language: 'en', target_language: 'id')
    expect(result[:skipped_reason]).to eq('not_configured')
  end

  it 'translates the answer back into the customer language' do
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: true, message: 'Halo, apa kabar', error: nil)

    result = described_class.new(text: 'Hello, how are you', source_language: 'en', target_language: 'id').call

    expect(result).to include(ok: true, translated: true, text: 'Halo, apa kabar', source_language: 'en', target_language: 'id')
  end

  it 'falls back to the original answer when the provider errors' do
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: false, message: nil, error: 'upstream boom')

    result = described_class.new(text: 'Hello, how are you', source_language: 'en', target_language: 'id').call

    expect(result).to include(ok: false, translated: false, text: 'Hello, how are you', error: 'upstream boom')
  end
end
