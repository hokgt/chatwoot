# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::Config do
  before do
    allow(InstallationConfig).to receive(:find_by).and_return(nil)
  end

  describe 'defaults when nothing is configured' do
    it 'returns default model, endpoint and embedding model' do
      expect(described_class.model).to eq('gpt-4.1-mini')
      expect(described_class.endpoint).to eq('https://api.openai.com')
      expect(described_class.embedding_model).to eq('text-embedding-3-small')
    end

    it 'reports not configured without an API key' do
      expect(described_class.configured?).to be(false)
    end

    it 'builds a versioned OpenAI-compatible base' do
      expect(described_class.api_base).to eq('https://api.openai.com/v1')
    end
  end

  describe 'when Marine keys are configured' do
    let(:api_key_config) { instance_double(InstallationConfig, value: 'sk-marine') }
    let(:endpoint_config) { instance_double(InstallationConfig, value: 'https://proxy.internal/') }
    let(:model_config) { instance_double(InstallationConfig, value: 'custom-model') }

    before do
      allow(InstallationConfig).to receive(:find_by).with(name: 'MARINE_OPEN_AI_API_KEY').and_return(api_key_config)
      allow(InstallationConfig).to receive(:find_by).with(name: 'MARINE_OPEN_AI_ENDPOINT').and_return(endpoint_config)
      allow(InstallationConfig).to receive(:find_by).with(name: 'MARINE_OPEN_AI_MODEL').and_return(model_config)
    end

    it 'reads Marine-specific values only' do
      expect(described_class.api_key).to eq('sk-marine')
      expect(described_class.model).to eq('custom-model')
      expect(described_class.api_base).to eq('https://proxy.internal/v1')
      expect(described_class.configured?).to be(true)
    end
  end

  describe '#api_base with versioned endpoints' do
    def stub_endpoint(value)
      allow(InstallationConfig).to receive(:find_by).with(name: 'MARINE_OPEN_AI_ENDPOINT')
                                                    .and_return(instance_double(InstallationConfig, value: value))
    end

    it 'does not append /v1 for the Gemini OpenAI-compat endpoint' do
      stub_endpoint('https://generativelanguage.googleapis.com/v1beta/openai')
      expect(described_class.api_base).to eq('https://generativelanguage.googleapis.com/v1beta/openai')
    end

    it 'does not append /v1 when the endpoint already ends with /v1' do
      stub_endpoint('https://proxy.internal/v1')
      expect(described_class.api_base).to eq('https://proxy.internal/v1')
    end

    it 'appends /v1 for a bare endpoint' do
      stub_endpoint('https://openrouter.ai/api')
      expect(described_class.api_base).to eq('https://openrouter.ai/api/v1')
    end
  end

  describe 'provider delegation' do
    it 'delegates provider and rubyllm_provider to ProviderConfig' do
      allow(Marine::Llm::ProviderConfig).to receive(:provider).and_return('anthropic')
      allow(Marine::Llm::ProviderConfig).to receive(:rubyllm_provider).and_return('anthropic')
      expect(described_class.provider).to eq('anthropic')
      expect(described_class.rubyllm_provider).to eq('anthropic')
    end
  end
end
