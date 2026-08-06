# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::LanguageDetector do
  it 'returns the unknown structure for blank text' do
    expect(described_class.new('   ').detect).to eq(described_class::UNKNOWN)
  end

  it 'returns a normalized structure with the expected keys' do
    result = described_class.new('This is a clear English sentence for detection.').detect

    expect(result.keys).to contain_exactly(:language, :reliable, :confidence)
    expect(result[:reliable]).to be_in([true, false])
    expect(result[:confidence]).to be_a(Float)
  end

  it 'detects Bahasa Indonesia via keyword heuristic without invoking CLD3' do
    expect(CLD3::NNetLanguageIdentifier).not_to receive(:new)

    result = described_class.new('Di mana alamat kantor Textilindo?').detect

    expect(result).to eq(described_class::INDONESIAN_RESULT)
    expect(result[:language]).to eq('id')
    expect(result[:reliable]).to be(true)
  end

  it 'detects Indonesian domain-marker queries as id' do
    expect(described_class.new('Apa email Textilindo?').detect[:language]).to eq('id')
    expect(described_class.new('Berapa MOQ untuk fabric dyeing?').detect[:language]).to eq('id')
  end

  it 'does not force id for clearly English text without Indonesian markers' do
    expect(described_class.new('Where is your head office located?').detect[:language]).not_to eq('id')
  end

  it 'fails safely to unknown when CLD3 raises' do
    fake = instance_double(CLD3::NNetLanguageIdentifier)
    allow(CLD3::NNetLanguageIdentifier).to receive(:new).and_return(fake)
    allow(fake).to receive(:find_language).and_raise(StandardError, 'boom')

    expect(described_class.new('hello world').detect).to eq(described_class::UNKNOWN)
  end
end
