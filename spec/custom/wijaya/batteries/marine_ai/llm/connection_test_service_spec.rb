# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::ConnectionTestService do
  let(:config_double) { double('RubyLLM config').as_null_object }
  let(:context_double) { instance_double(RubyLLM::Context) }
  let(:chat_double) { double('RubyLLM chat') }

  describe '#call' do
    context 'when no API key is provided' do
      it 'fails fast without hitting RubyLLM' do
        expect(RubyLLM).not_to receive(:context)
        result = described_class.new(provider: 'openai', api_key: '').call
        expect(result).to include(ok: false)
        expect(result[:error]).to be_present
      end
    end

    context 'when the provider responds successfully' do
      before do
        allow(RubyLLM).to receive(:context).and_yield(config_double).and_return(context_double)
        allow(context_double).to receive(:chat).and_return(chat_double)
        allow(chat_double).to receive(:ask).and_return(double(content: 'pong'))
      end

      it 'returns ok true and never leaks the api key' do
        result = described_class.new(provider: 'openai', api_key: 'sk-secret', model: 'gpt-4.1-mini').call
        expect(result[:ok]).to be(true)
        expect(result[:error]).to be_nil
        expect(result.to_s).not_to include('sk-secret')
      end

      it 'targets the openai adapter for gemini via the openai config' do
        expect(context_double).to receive(:chat).with(hash_including(provider: 'openai')).and_return(chat_double)
        described_class.new(provider: 'gemini', api_key: 'gem-key', model: 'gemini-2.0-flash').call
      end

      it 'targets the anthropic adapter for anthropic' do
        expect(context_double).to receive(:chat).with(hash_including(provider: 'anthropic')).and_return(chat_double)
        described_class.new(provider: 'anthropic', api_key: 'ant-key', model: 'claude-sonnet-4-20250514').call
      end
    end

    context 'when the chat path is used (default mode)' do
      it 'never builds the Decisions client' do
        allow(RubyLLM).to receive(:context).and_yield(config_double).and_return(context_double)
        allow(context_double).to receive(:chat).and_return(chat_double)
        allow(chat_double).to receive(:ask).and_return(double(content: 'pong'))
        expect(Marine::Llm::OpenrouterDecisionsClient).not_to receive(:new)

        described_class.new(provider: 'openrouter', api_key: 'sk-or-key', model: 'nvidia/nemotron').call
      end
    end

    context 'when api_mode is openrouter_decisions' do
      it 'delegates to the Decisions client and never touches RubyLLM chat' do
        expect(RubyLLM).not_to receive(:context)
        client = instance_double(Marine::Llm::OpenrouterDecisionsClient, test_connection: { ok: true, message: 'ok', error: nil })
        expect(Marine::Llm::OpenrouterDecisionsClient).to receive(:new)
          .with(hash_including(api_key: 'sk-or-key', model: 'typesafe/jev-1.13'))
          .and_return(client)

        result = described_class.new(
          provider: 'openrouter', api_key: 'sk-or-key', endpoint: 'https://openrouter.ai/api',
          model: 'typesafe/jev-1.13', api_mode: 'openrouter_decisions'
        ).call

        expect(result[:ok]).to be(true)
      end

      it 'surfaces a Decisions client failure as a failed result' do
        client = instance_double(Marine::Llm::OpenrouterDecisionsClient, test_connection: { ok: false, message: nil, error: 'HTTP 401' })
        allow(Marine::Llm::OpenrouterDecisionsClient).to receive(:new).and_return(client)

        result = described_class.new(
          provider: 'openrouter', api_key: 'sk-or-key', model: 'typesafe/jev-1.13', api_mode: 'openrouter_decisions'
        ).call

        expect(result[:ok]).to be(false)
        expect(result[:error]).to eq('HTTP 401')
      end
    end

    context 'when the provider raises an error' do
      before do
        allow(RubyLLM).to receive(:context).and_yield(config_double).and_return(context_double)
        allow(context_double).to receive(:chat).and_return(chat_double)
        allow(chat_double).to receive(:ask).and_raise(StandardError, 'invalid api key')
      end

      it 'returns ok false with the error message' do
        result = described_class.new(provider: 'openai', api_key: 'sk-bad', model: 'gpt-4.1-mini').call
        expect(result[:ok]).to be(false)
        expect(result[:error]).to eq('invalid api key')
      end
    end
  end
end
