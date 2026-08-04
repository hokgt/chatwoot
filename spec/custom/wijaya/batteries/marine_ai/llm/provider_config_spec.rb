# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::ProviderConfig do
  def stub_provider(value)
    config = value.nil? ? nil : instance_double(InstallationConfig, value: value)
    allow(InstallationConfig).to receive(:find_by).with(name: 'MARINE_LLM_PROVIDER').and_return(config)
  end

  describe '.provider' do
    it 'defaults to openai when unset' do
      stub_provider(nil)
      expect(described_class.provider).to eq('openai')
    end

    it 'returns the configured provider when supported' do
      stub_provider('gemini')
      expect(described_class.provider).to eq('gemini')
    end

    it 'falls back to openai for an unknown provider' do
      stub_provider('unknown-provider')
      expect(described_class.provider).to eq('openai')
    end
  end

  describe '.rubyllm_provider' do
    it 'maps gemini to the openai adapter' do
      expect(described_class.rubyllm_provider('gemini')).to eq('openai')
    end

    it 'maps anthropic to the anthropic adapter' do
      expect(described_class.rubyllm_provider('anthropic')).to eq('anthropic')
    end

    it 'maps openrouter to the openai adapter' do
      expect(described_class.rubyllm_provider('openrouter')).to eq('openai')
    end
  end

  describe '.supports_embeddings?' do
    it 'is true for openai' do
      expect(described_class.supports_embeddings?('openai')).to be(true)
    end

    it 'is false for openrouter' do
      expect(described_class.supports_embeddings?('openrouter')).to be(false)
    end

    it 'is false for anthropic' do
      expect(described_class.supports_embeddings?('anthropic')).to be(false)
    end
  end

  describe '.available_providers' do
    it 'lists every provider with metadata for the UI' do
      keys = described_class.available_providers.map { |provider| provider[:value] }
      expect(keys).to contain_exactly('openai', 'openrouter', 'gemini', 'anthropic', 'custom')
      expect(described_class.available_providers.first.keys).to include(:value, :label, :default_endpoint, :default_model, :supports_embeddings)
    end
  end
end
