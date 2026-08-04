# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::TranslateQueryService do
  let(:base_service) { instance_double(Marine::Llm::BaseService) }

  def stub_detection(language)
    allow(Marine::Llm::LanguageDetector).to receive(:new).and_return(
      instance_double(Marine::Llm::LanguageDetector, detect: { language: language, reliable: true, confidence: 0.9 })
    )
  end

  before do
    allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
  end

  it 'is a no-op when the query is already in the target language' do
    stub_detection('en')
    expect(base_service).not_to receive(:complete)

    result = described_class.new(text: 'Hello there', target_language: 'en').call

    expect(result).to include(translated: false, text: 'Hello there', source_language: 'en', target_language: 'en', error: nil)
    expect(result[:skipped_reason]).to eq('same_language')
  end

  it 'degrades safely when the source language is unknown' do
    stub_detection('unknown')
    expect(base_service).not_to receive(:complete)

    result = described_class.new(text: '???', target_language: 'en').call

    expect(result).to include(translated: false, text: '???', source_language: nil, error: nil)
    expect(result[:skipped_reason]).to eq('unknown_source_language')
  end

  it 'degrades safely for blank input' do
    stub_detection('unknown')

    result = described_class.new(text: '   ', target_language: 'en').call

    expect(result).to include(translated: false, error: nil)
    expect(result[:skipped_reason]).to eq('blank_input')
  end

  it 'does not call the provider when Marine LLM is not configured' do
    stub_detection('id')
    allow(base_service).to receive(:configured?).and_return(false)
    expect(base_service).not_to receive(:complete)

    result = described_class.new(text: 'Halo, apa kabar', target_language: 'en').call

    expect(result).to include(translated: false, text: 'Halo, apa kabar', source_language: 'id')
    expect(result[:skipped_reason]).to eq('not_configured')
  end

  it 'translates when configured and languages differ' do
    stub_detection('id')
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: true, message: 'Hello, how are you', error: nil)

    result = described_class.new(text: 'Halo, apa kabar', target_language: 'en').call

    expect(result).to include(ok: true, translated: true, text: 'Hello, how are you', source_language: 'id', target_language: 'en')
  end

  it 'falls back to the original text when the provider errors' do
    stub_detection('id')
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: false, message: nil, error: 'upstream boom')

    result = described_class.new(text: 'Halo, apa kabar', target_language: 'en').call

    expect(result).to include(ok: false, translated: false, text: 'Halo, apa kabar', error: 'upstream boom')
  end
end
