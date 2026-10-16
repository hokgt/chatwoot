# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 2 — the settings-bound transport facade. These examples pin that the
# client reads ONLY the decision-maker settings, selects a transport SOLELY from the
# allowlisted api_mode, validates configuration before any network call, and rejects
# unknown/mixed protocol keys fail-closed. No real transport is invoked here.
RSpec.describe Marine::Decision::Client do
  let(:chat_transport) { instance_double(Marine::Decision::ChatCompletionsClient) }
  let(:decisions_transport) { instance_double(Marine::Decision::OpenrouterDecisionsClient) }

  def settings(overrides = {})
    instance_double(
      Marine::Llm::SettingsStore,
      { api_mode: 'chat_completions', provider: 'openai', model: 'gpt-4.1-mini',
        endpoint: 'https://api.openai.com', api_key: 'sk-decision-secret' }.merge(overrides)
    )
  end

  it 'reads the decision-maker settings by default' do
    expect(Marine::Llm::SettingsStore).to receive(:for).with(:decision_maker).and_return(settings)
    allow(Marine::Decision::ChatCompletionsClient).to receive(:new).and_return(chat_transport)
    allow(chat_transport).to receive(:call).and_return(:chat_result)

    expect(described_class.new.call(messages: [{ role: 'user', content: 'hi' }])).to eq(:chat_result)
  end

  it 'selects the chat transport for chat_completions, configured from the injected settings only' do
    expect(Marine::Decision::ChatCompletionsClient).to receive(:new).with(
      provider: 'openai', model: 'gpt-4.1-mini', endpoint: 'https://api.openai.com', api_key: 'sk-decision-secret'
    ).and_return(chat_transport)
    expect(Marine::Decision::OpenrouterDecisionsClient).not_to receive(:new)
    allow(chat_transport).to receive(:call).and_return(:chat_result)

    result = described_class.new(settings: settings).call(messages: [{ role: 'user', content: 'hi' }])

    expect(result).to eq(:chat_result)
  end

  it 'selects the decisions transport for openrouter_decisions' do
    store = settings(api_mode: 'openrouter_decisions', provider: 'openrouter', endpoint: 'https://openrouter.ai/api')
    expect(Marine::Decision::OpenrouterDecisionsClient).to receive(:new).with(
      model: 'gpt-4.1-mini', endpoint: 'https://openrouter.ai/api', api_key: 'sk-decision-secret'
    ).and_return(decisions_transport)
    expect(Marine::Decision::ChatCompletionsClient).not_to receive(:new)
    allow(decisions_transport).to receive(:call).and_return(:decisions_result)

    result = described_class.new(settings: store).call(questions: { q1: { type: 'choice' } })

    expect(result).to eq(:decisions_result)
  end

  context 'when the configuration is unusable' do
    before do
      allow(Marine::Decision::ChatCompletionsClient).to receive(:new)
      allow(Marine::Decision::OpenrouterDecisionsClient).to receive(:new)
    end

    it 'fails closed with unconfigured for an unrecognized api_mode without touching a transport' do
      result = described_class.new(settings: settings(api_mode: 'mystery_mode')).call(messages: [])

      expect(result).to include(ok: false, error_reason: 'unconfigured', api_mode: nil, payload: nil)
      expect(Marine::Decision::ChatCompletionsClient).not_to have_received(:new)
    end

    it 'fails closed with unconfigured when the api key is blank' do
      result = described_class.new(settings: settings(api_key: '')).call(messages: [{ role: 'user', content: 'hi' }])

      expect(result).to include(ok: false, error_reason: 'unconfigured', api_mode: 'chat_completions')
      expect(Marine::Decision::ChatCompletionsClient).not_to have_received(:new)
    end

    it 'fails closed with unconfigured when the model is blank' do
      result = described_class.new(settings: settings(model: '')).call(messages: [{ role: 'user', content: 'hi' }])

      expect(result).to include(ok: false, error_reason: 'unconfigured')
    end

    it 'fails closed with unconfigured for a non-allowlisted provider' do
      result = described_class.new(settings: settings(provider: 'evilcorp')).call(messages: [{ role: 'user', content: 'hi' }])

      expect(result).to include(ok: false, error_reason: 'unconfigured')
    end

    it 'fails closed with unconfigured for a malformed endpoint' do
      %w[not-a-url ftp://x.test https://user:pass@host.test].each do |endpoint|
        result = described_class.new(settings: settings(endpoint: endpoint)).call(messages: [{ role: 'user', content: 'hi' }])
        expect(result).to include(ok: false, error_reason: 'unconfigured'), "expected #{endpoint} to be rejected"
      end
      expect(Marine::Decision::ChatCompletionsClient).not_to have_received(:new)
    end
  end

  context 'when a settings read or transport raises (fail-closed completeness)' do
    it 'folds a raising api_mode getter to provider_error with a nil api_mode and no error text' do
      store = settings
      allow(store).to receive(:api_mode).and_raise(StandardError, "boom #{store.api_key}")

      result = described_class.new(settings: store).call(messages: [{ role: 'user', content: 'hi' }])

      expect(result).to include(ok: false, error_reason: 'provider_error', api_mode: nil, payload: nil)
      expect(result.to_s).not_to include('boom')
      expect(result.to_s).not_to include('sk-decision-secret')
    end

    it 'folds a later raising settings getter to provider_error, preserving the allowlisted api_mode' do
      store = settings
      allow(store).to receive(:model).and_raise(StandardError, 'kaboom')

      result = described_class.new(settings: store).call(messages: [{ role: 'user', content: 'hi' }])

      expect(result).to include(ok: false, error_reason: 'provider_error', api_mode: 'chat_completions')
      expect(result.to_s).not_to include('kaboom')
    end

    it 'folds a raising transport constructor to provider_error' do
      allow(Marine::Decision::ChatCompletionsClient).to receive(:new).and_raise(StandardError, 'ctor boom')

      result = described_class.new(settings: settings).call(messages: [{ role: 'user', content: 'hi' }])

      expect(result).to include(ok: false, error_reason: 'provider_error', api_mode: 'chat_completions')
      expect(result.to_s).not_to include('ctor boom')
    end

    it 'folds a raising transport dispatch to provider_error' do
      allow(Marine::Decision::ChatCompletionsClient).to receive(:new).and_return(chat_transport)
      allow(chat_transport).to receive(:call).and_raise(StandardError, 'dispatch boom')

      result = described_class.new(settings: settings).call(messages: [{ role: 'user', content: 'hi' }])

      expect(result).to include(ok: false, error_reason: 'provider_error', api_mode: 'chat_completions')
      expect(result.to_s).not_to include('dispatch boom')
    end
  end

  context 'with unknown or mixed protocol keys' do
    before do
      allow(Marine::Decision::ChatCompletionsClient).to receive(:new).and_return(chat_transport)
      allow(chat_transport).to receive(:call) { |request| request }
      allow(Marine::Decision::OpenrouterDecisionsClient).to receive(:new).and_return(decisions_transport)
      allow(decisions_transport).to receive(:call) { |request| request }
    end

    it 'rejects an unknown key fail-closed without invoking a transport' do
      result = described_class.new(settings: settings).call(messages: [{ role: 'user', content: 'hi' }], tools: [:danger])

      expect(result).to include(ok: false, error_reason: 'malformed_response', api_mode: 'chat_completions')
      expect(chat_transport).not_to have_received(:call)
    end

    it 'rejects a decisions key mixed into a chat request' do
      result = described_class.new(settings: settings).call(messages: [], questions: {})

      expect(result).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'rejects a duplicate canonical top-level key before symbolization, without a transport' do
      result = described_class.new(settings: settings).call('messages' => [], :messages => [{ role: 'user', content: 'hi' }])

      expect(result).to include(ok: false, error_reason: 'malformed_response', api_mode: 'chat_completions')
      expect(chat_transport).not_to have_received(:call)
    end

    it 'forwards a symbolized copy and never mutates the caller request' do
      request = { 'messages' => [{ 'role' => 'user', 'content' => 'hi' }], 'temperature' => 0 }
      original = Marshal.load(Marshal.dump(request))

      forwarded = described_class.new(settings: settings).call(request)

      expect(forwarded).to eq(messages: [{ 'role' => 'user', 'content' => 'hi' }], temperature: 0)
      expect(request).to eq(original)
    end
  end
end
