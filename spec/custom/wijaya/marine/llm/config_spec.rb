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
end
