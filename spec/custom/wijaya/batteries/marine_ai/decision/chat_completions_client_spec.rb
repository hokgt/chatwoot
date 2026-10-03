# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 2 — the chat/completions Decision transport. These examples pin that
# the client builds an ISOLATED RubyLLM context from the injected settings only, forwards
# a validated conversation (never building prompts), serializes a structured Hash reply,
# and fails closed to an opaque allowlisted reason on nil/other/blank/oversized output or
# any error — never leaking the key, body, or exception text. No real network.
RSpec.describe Marine::Decision::ChatCompletionsClient do
  subject(:client) do
    described_class.new(provider: 'openai', model: 'gpt-4.1-mini', endpoint: 'https://api.openai.com', api_key: api_key)
  end

  let(:api_key) { 'sk-decision-secret-1234' }
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:response) { instance_double(RubyLLM::Message, content: 'classified: stock') }

  def stub_chat!
    allow(client).to receive(:build_chat).and_return(chat)
    %i[with_instructions with_temperature with_schema add_message].each { |message| allow(chat).to receive(message) }
    allow(chat).to receive(:ask).and_return(response)
  end

  describe 'isolated context configuration' do
    it 'configures RubyLLM from the injected decision settings only' do
      captured = Struct.new(:openai_api_key, :openai_api_base, :request_timeout, :max_retries).new
      context = instance_double(RubyLLM::Context)
      allow(RubyLLM).to receive(:context).and_yield(captured).and_return(context)
      allow(context).to receive(:chat).and_return(chat)
      allow(chat).to receive(:ask).and_return(response)

      expect(context).to receive(:chat).with(model: 'gpt-4.1-mini', provider: 'openai', assume_model_exists: true)

      client.call(messages: [{ role: 'user', content: 'hi' }])

      expect(captured.openai_api_key).to eq(api_key)
      expect(captured.openai_api_base).to eq('https://api.openai.com/v1')
      expect(captured.max_retries).to eq(0)
    end

    it 'configures the anthropic base from the injected endpoint (raw, no /v1 — the provider appends v1/messages)' do
      captured = Struct.new(:anthropic_api_key, :anthropic_api_base, :request_timeout, :max_retries).new
      context = instance_double(RubyLLM::Context)
      allow(RubyLLM).to receive(:context).and_yield(captured).and_return(context)
      allow(context).to receive(:chat).and_return(chat)
      %i[with_instructions with_temperature with_schema add_message].each { |message| allow(chat).to receive(message) }
      allow(chat).to receive(:ask).and_return(response)

      anthropic = described_class.new(provider: 'anthropic', model: 'claude-sonnet-4', endpoint: 'https://api.anthropic.com/', api_key: api_key)
      anthropic.call(messages: [{ role: 'user', content: 'hi' }])

      expect(captured.anthropic_api_key).to eq(api_key)
      expect(captured.anthropic_api_base).to eq('https://api.anthropic.com')
    end
  end

  describe '#call' do
    it 'forwards the conversation and returns a bounded content String payload' do
      stub_chat!

      result = client.call(messages: [{ role: 'user', content: 'stock?' }], system: 'be terse', temperature: 0)

      expect(result).to include(ok: true, payload: 'classified: stock', error_reason: nil,
                                model: 'gpt-4.1-mini', api_mode: 'chat_completions')
      expect(chat).to have_received(:with_instructions).with('be terse')
      expect(chat).to have_received(:with_temperature).with(0)
      expect(chat).to have_received(:ask).with('stock?')
    end

    it 'passes an earlier turn via add_message and asks with the final turn' do
      stub_chat!

      client.call(messages: [
                    { role: 'user', content: 'first' },
                    { role: 'assistant', content: 'ok' },
                    { role: 'user', content: 'second' }
                  ])

      expect(chat).to have_received(:add_message).with(role: :user, content: 'first')
      expect(chat).to have_received(:add_message).with(role: :assistant, content: 'ok')
      expect(chat).to have_received(:ask).with('second')
    end

    it 'enforces a schema and serializes a structured Hash reply to JSON' do
      stub_chat!
      allow(response).to receive(:content).and_return({ 'scenario' => 'stock', 'confidence' => 'high' })
      schema = { name: 'plan', schema: { type: 'object' } }

      result = client.call(messages: [{ role: 'user', content: 'hi' }], schema: schema)

      expect(chat).to have_received(:with_schema).with(schema)
      expect(result[:payload]).to eq('{"scenario":"stock","confidence":"high"}')
    end

    it 'fails closed to malformed_response for nil content' do
      stub_chat!
      allow(response).to receive(:content).and_return(nil)

      expect(client.call(messages: [{ role: 'user', content: 'hi' }])).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'fails closed to malformed_response for a non-string, non-schema reply' do
      stub_chat!
      allow(response).to receive(:content).and_return({ 'x' => 1 })

      expect(client.call(messages: [{ role: 'user', content: 'hi' }])).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'fails closed to malformed_response for a blank reply' do
      stub_chat!
      allow(response).to receive(:content).and_return('')

      expect(client.call(messages: [{ role: 'user', content: 'hi' }])).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'fails closed to malformed_response for oversized output' do
      stub_chat!
      allow(response).to receive(:content).and_return('a' * (described_class::MAX_OUTPUT_BYTES + 1))

      expect(client.call(messages: [{ role: 'user', content: 'hi' }])).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'maps a timeout error to the timeout reason' do
      stub_chat!
      allow(chat).to receive(:ask).and_raise(Timeout::Error)

      expect(client.call(messages: [{ role: 'user', content: 'hi' }])).to include(ok: false, error_reason: 'timeout')
    end

    it 'maps any other error to provider_error and never leaks the message' do
      stub_chat!
      allow(chat).to receive(:ask).and_raise(StandardError, "boom with #{api_key}")

      result = client.call(messages: [{ role: 'user', content: 'hi' }])

      expect(result).to include(ok: false, error_reason: 'provider_error')
      expect(result.to_s).not_to include(api_key)
    end

    it 'rejects an empty/invalid conversation without any network call' do
      expect(RubyLLM).not_to receive(:context)

      expect(client.call(messages: [])).to include(ok: false, error_reason: 'malformed_response')
      expect(client.call(messages: [{ role: 'system', content: 'x' }])).to include(ok: false, error_reason: 'malformed_response')
      expect(client.call(messages: 'nope')).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'does not place the API key in a successful result' do
      stub_chat!

      expect(client.call(messages: [{ role: 'user', content: 'hi' }]).to_s).not_to include(api_key)
    end

    it 'does not mutate the caller request' do
      stub_chat!
      request = { messages: [{ role: 'user', content: 'hi' }], temperature: 0 }
      original = Marshal.load(Marshal.dump(request))

      client.call(request)

      expect(request).to eq(original)
    end
  end

  describe 'strict request bounds before any network' do
    it 'rejects oversized per-message content without any network' do
      expect(RubyLLM).not_to receive(:context)

      result = client.call(messages: [{ role: 'user', content: 'a' * (described_class::MAX_CONTENT_BYTES + 1) }])

      expect(result).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'rejects an oversized system instruction without any network' do
      expect(RubyLLM).not_to receive(:context)

      result = client.call(messages: [{ role: 'user', content: 'hi' }], system: 's' * (described_class::MAX_SYSTEM_BYTES + 1))

      expect(result).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'rejects a non-string system rather than silently dropping it' do
      expect(client.call(messages: [{ role: 'user', content: 'hi' }], system: { a: 1 })).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'rejects a non-hash schema rather than silently dropping it' do
      expect(client.call(messages: [{ role: 'user', content: 'hi' }], schema: 'nope')).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'rejects a non-numeric, out-of-range, or non-finite temperature' do
      ['hot', -1, 2.5, Float::NAN, Float::INFINITY].each do |bad|
        expect(client.call(messages: [{ role: 'user', content: 'hi' }], temperature: bad)).to(
          include(ok: false, error_reason: 'malformed_response'), "expected temperature #{bad.inspect} to be rejected"
        )
      end
    end

    it 'rejects an unknown top-level key without any network' do
      expect(RubyLLM).not_to receive(:context)

      expect(client.call(messages: [{ role: 'user', content: 'hi' }], tools: [:danger])).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'rejects a duplicate canonical top-level key without any network' do
      expect(RubyLLM).not_to receive(:context)

      expect(client.call('messages' => [{ role: 'user', content: 'hi' }], :messages => [])).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'rejects a message with an unknown key' do
      expect(client.call(messages: [{ role: 'user', content: 'hi', tool: 'x' }])).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'rejects a message with a duplicate canonical key' do
      message = { 'role' => 'user', :role => 'user', 'content' => 'hi' }

      expect(client.call(messages: [message])).to include(ok: false, error_reason: 'malformed_response')
    end
  end
end
