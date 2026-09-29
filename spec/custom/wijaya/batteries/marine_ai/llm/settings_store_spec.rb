# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::SettingsStore do
  def set_config(name, value)
    config = InstallationConfig.where(name: name).first_or_initialize
    config.value = value
    config.locked = false
    config.save!
  end

  describe '.for' do
    it 'rejects an unknown target' do
      expect { described_class.for('nope') }.to raise_error(ArgumentError)
    end

    it 'accepts the two known targets as strings or symbols' do
      expect(described_class.for('decision_maker')).to be_a(described_class)
      expect(described_class.for(:response_generator)).to be_a(described_class)
    end
  end

  describe 'response_generator' do
    it 'maps to the legacy runtime keys so the runner stays in step' do
      set_config('MARINE_LLM_PROVIDER', 'openrouter')
      set_config('MARINE_OPEN_AI_MODEL', 'nvidia/nemotron')
      set_config('MARINE_OPEN_AI_ENDPOINT', 'https://openrouter.ai/api')
      set_config('MARINE_OPEN_AI_API_KEY', 'sk-or-1234567890abcd')

      store = described_class.for(:response_generator)

      expect(store.provider).to eq('openrouter')
      expect(store.model).to eq('nvidia/nemotron')
      expect(store.endpoint).to eq('https://openrouter.ai/api')
      expect(store.api_key).to eq('sk-or-1234567890abcd')
    end

    it 'writes back to the legacy keys and preserves a blank api_key' do
      set_config('MARINE_OPEN_AI_API_KEY', 'sk-existing-key-9999')

      described_class.for(:response_generator).write(
        provider: 'gemini', model: 'gemini-2.0-flash',
        endpoint: 'https://generativelanguage.googleapis.com/v1beta/openai', api_key: ''
      )

      expect(InstallationConfig.find_by(name: 'MARINE_LLM_PROVIDER').value).to eq('gemini')
      expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_MODEL').value).to eq('gemini-2.0-flash')
      expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_API_KEY').value).to eq('sk-existing-key-9999')
    end
  end

  describe 'decision_maker' do
    it 'falls back to the response generator config when unset (fresh install)' do
      set_config('MARINE_LLM_PROVIDER', 'openrouter')
      set_config('MARINE_OPEN_AI_MODEL', 'nvidia/nemotron')
      set_config('MARINE_OPEN_AI_API_KEY', 'sk-or-shared-key-123')

      store = described_class.for(:decision_maker)

      expect(store.provider).to eq('openrouter')
      expect(store.model).to eq('nvidia/nemotron')
      expect(store.api_key).to eq('sk-or-shared-key-123')
    end

    it 'uses its own keys once configured independently' do
      set_config('MARINE_OPEN_AI_MODEL', 'nvidia/nemotron')
      set_config('MARINE_OPEN_AI_API_KEY', 'sk-response-key-123')
      set_config('MARINE_DECISION_LLM_PROVIDER', 'gemini')
      set_config('MARINE_DECISION_LLM_MODEL', 'gemini-2.5-flash')
      set_config('MARINE_DECISION_LLM_API_KEY', 'gem-decision-key-456')

      store = described_class.for(:decision_maker)

      expect(store.provider).to eq('gemini')
      expect(store.model).to eq('gemini-2.5-flash')
      expect(store.api_key).to eq('gem-decision-key-456')
    end

    it 'writes only its own keys and never touches the runtime keys' do
      set_config('MARINE_LLM_PROVIDER', 'openrouter')
      set_config('MARINE_OPEN_AI_MODEL', 'nvidia/nemotron')
      set_config('MARINE_OPEN_AI_API_KEY', 'sk-response-key-123')

      described_class.for(:decision_maker).write(
        provider: 'gemini', model: 'gemini-2.5-flash',
        endpoint: 'https://generativelanguage.googleapis.com/v1beta/openai', api_key: 'gem-decision-key-456'
      )

      expect(InstallationConfig.find_by(name: 'MARINE_DECISION_LLM_PROVIDER').value).to eq('gemini')
      expect(InstallationConfig.find_by(name: 'MARINE_DECISION_LLM_API_KEY').value).to eq('gem-decision-key-456')
      # Runtime keys are untouched.
      expect(InstallationConfig.find_by(name: 'MARINE_LLM_PROVIDER').value).to eq('openrouter')
      expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_MODEL').value).to eq('nvidia/nemotron')
      expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_API_KEY').value).to eq('sk-response-key-123')
    end

    it 'preserves its own stored key when api_key is blank, independent of the response key' do
      set_config('MARINE_OPEN_AI_API_KEY', 'sk-response-key-123')
      set_config('MARINE_DECISION_LLM_API_KEY', 'gem-decision-key-456')

      described_class.for(:decision_maker).write(provider: 'gemini', api_key: '')

      expect(InstallationConfig.find_by(name: 'MARINE_DECISION_LLM_API_KEY').value).to eq('gem-decision-key-456')
    end

    it 'seeds its own key from the effective fallback the first time it is saved without a key' do
      set_config('MARINE_OPEN_AI_API_KEY', 'sk-legacy-fallback-1')

      described_class.for(:decision_maker).write(provider: 'gemini', api_key: '')

      # The fallback is materialized into the decision-specific key…
      expect(InstallationConfig.find_by(name: 'MARINE_DECISION_LLM_API_KEY').value).to eq('sk-legacy-fallback-1')
      # …without touching the legacy/runtime key it copied from.
      expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_API_KEY').value).to eq('sk-legacy-fallback-1')
    end

    it 'does not create a blank decision key row when no fallback key exists' do
      described_class.for(:decision_maker).write(provider: 'gemini', api_key: '')

      expect(InstallationConfig.find_by(name: 'MARINE_DECISION_LLM_API_KEY')).to be_nil
    end

    it 'stays on its seeded key after the response generator key later changes' do
      set_config('MARINE_OPEN_AI_API_KEY', 'sk-legacy-fallback-1')

      # First save with no explicit key seeds independence…
      described_class.for(:decision_maker).write(provider: 'gemini', api_key: '')
      # …then the response generator key is rotated.
      described_class.for(:response_generator).write(api_key: 'sk-rotated-2')

      expect(described_class.for(:decision_maker).api_key).to eq('sk-legacy-fallback-1')
      expect(described_class.for(:response_generator).api_key).to eq('sk-rotated-2')
    end
  end

  describe '#to_view' do
    it 'masks the key and exposes presence + provider metadata, never plaintext' do
      set_config('MARINE_LLM_PROVIDER', 'openrouter')
      set_config('MARINE_OPEN_AI_API_KEY', 'sk-or-1234567890abcd')

      view = described_class.for(:response_generator).to_view

      expect(view[:provider]).to eq('openrouter')
      expect(view[:provider_label]).to eq('OpenRouter')
      expect(view[:api_endpoint]).to be_present
      expect(view[:api_key_masked]).to eq('sk-or-...abcd')
      expect(view[:api_key_present]).to be(true)
      expect(view[:supports_embeddings]).to be(false)
      expect(view.values.join).not_to include('sk-or-1234567890abcd')
    end

    it 'returns safe defaults with no MARINE_* rows present' do
      expect(InstallationConfig.where('name LIKE ?', 'MARINE_%')).to be_empty

      view = described_class.for(:decision_maker).to_view

      expect(view[:provider]).to eq('openai')
      expect(view[:api_key_present]).to be(false)
      expect(view[:configured]).to be(false)
    end

    it 'flags the decision maker key as inherited while it reads through the fallback' do
      set_config('MARINE_OPEN_AI_API_KEY', 'sk-response-key-123')

      expect(described_class.for(:decision_maker).to_view[:api_key_inherited]).to be(true)
      # The response generator IS the source, so it is never inherited.
      expect(described_class.for(:response_generator).to_view[:api_key_inherited]).to be(false)
    end

    it 'stops flagging the decision maker key as inherited once it has its own' do
      set_config('MARINE_OPEN_AI_API_KEY', 'sk-response-key-123')
      set_config('MARINE_DECISION_LLM_API_KEY', 'gem-decision-key-456')

      expect(described_class.for(:decision_maker).to_view[:api_key_inherited]).to be(false)
    end
  end
end
