# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::ReplyLocalizer do
  # Generic fake reply text — never a real product name or a language-specific phrase map.
  let(:english_text) { 'Here is the product catalog for Widget Base.' }

  def detector_for(language)
    instance_double(Marine::Llm::LanguageDetector, detect: { language: language, reliable: true, confidence: 1.0 })
  end

  it 'translates the English reply into the language detected from the trigger message' do
    allow(Marine::Llm::LanguageDetector).to receive(:new).with('mau lihat katalog').and_return(detector_for('id'))
    translator = instance_double(Marine::Llm::TranslateResponseService, call: { ok: true, text: 'LOCALIZED', translated: true })
    expect(Marine::Llm::TranslateResponseService).to receive(:new)
      .with(text: english_text, target_language: 'id', source_language: 'en', account: nil).and_return(translator)

    result = described_class.new(text: english_text, trigger_text: 'mau lihat katalog').call

    expect(result).to eq('LOCALIZED')
  end

  it 'leaves an English (source-language) reply untouched and never calls the translator' do
    allow(Marine::Llm::LanguageDetector).to receive(:new).with('do you have the catalog').and_return(detector_for('en'))
    expect(Marine::Llm::TranslateResponseService).not_to receive(:new)

    result = described_class.new(text: english_text, trigger_text: 'do you have the catalog').call

    expect(result).to eq(english_text)
  end

  it 'falls back to a bounded customer context when the short trigger cannot be classified' do
    allow(Marine::Llm::LanguageDetector).to receive(:new).with('iya').and_return(detector_for('unknown'))
    allow(Marine::Llm::LanguageDetector).to receive(:new).with('boleh minta katalognya').and_return(detector_for('id'))
    translator = instance_double(Marine::Llm::TranslateResponseService, call: { ok: true, text: 'LOCALIZED', translated: true })
    expect(Marine::Llm::TranslateResponseService).to receive(:new)
      .with(text: english_text, target_language: 'id', source_language: 'en', account: nil).and_return(translator)

    result = described_class.new(text: english_text, trigger_text: 'iya', context: ['boleh minta katalognya']).call

    expect(result).to eq('LOCALIZED')
  end

  it 'returns the original text when neither the trigger nor the context yields a language' do
    allow(Marine::Llm::LanguageDetector).to receive(:new).with('hi').and_return(detector_for('unknown'))
    allow(Marine::Llm::LanguageDetector).to receive(:new).with('hello').and_return(detector_for('unknown'))
    expect(Marine::Llm::TranslateResponseService).not_to receive(:new)

    result = described_class.new(text: english_text, trigger_text: 'hi', context: ['hello']).call

    expect(result).to eq(english_text)
  end

  it 'degrades to the original English when the translator returns it unchanged (skip/failure)' do
    allow(Marine::Llm::LanguageDetector).to receive(:new).and_return(detector_for('id'))
    # TranslateResponseService never raises: on skip/failure it returns the original text back.
    translator = instance_double(Marine::Llm::TranslateResponseService,
                                 call: { ok: false, text: english_text, translated: false, error: 'boom' })
    allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(translator)

    result = described_class.new(text: english_text, trigger_text: 'halo').call

    expect(result).to eq(english_text)
  end

  it 'returns blank text without detecting or translating' do
    expect(Marine::Llm::LanguageDetector).not_to receive(:new)
    expect(Marine::Llm::TranslateResponseService).not_to receive(:new)

    result = described_class.new(text: '   ', trigger_text: 'iya').call

    expect(result).to eq('   ')
  end
end
