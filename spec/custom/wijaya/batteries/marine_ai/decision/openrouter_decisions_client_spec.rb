# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 2 — the OpenRouter Decisions transport. These examples pin the exact
# endpoint/body/header, that ONLY a bounded deep-copied `answers` payload is returned,
# request structure/bounds are validated before the network, and every failure maps to an
# opaque allowlisted reason without leaking the key, body, or exception text. WebMock only.
RSpec.describe Marine::Decision::OpenrouterDecisionsClient do
  subject(:client) { described_class.new(model: model, endpoint: 'https://openrouter.ai/api', api_key: api_key) }

  let(:api_key) { 'sk-or-decisions-secret-1234' }
  let(:model) { 'typesafe/jev-1.13' }
  let(:decisions_url) { 'https://openrouter.ai/api/alpha/decisions' }
  let(:questions) { { 'intent' => { 'type' => 'choice', 'criteria' => { 'stock' => 'about stock' } } } }
  let(:state) { { 'turn' => 1 } }

  def call(request = { questions: questions, state: state })
    client.call(request)
  end

  describe '#decisions_url' do
    it 'mirrors the tested OpenRouter normalization' do
      expect(described_class.new(model: model, endpoint: 'https://openrouter.ai', api_key: api_key).decisions_url).to eq(decisions_url)
      expect(described_class.new(model: model, endpoint: 'https://openrouter.ai/api/', api_key: api_key).decisions_url).to eq(decisions_url)
      expect(described_class.new(model: model, endpoint: decisions_url, api_key: api_key).decisions_url).to eq(decisions_url)
    end
  end

  describe '#call success' do
    it 'POSTs exactly model/questions/state with a bearer token and returns only the answers' do
      stub = stub_request(:post, decisions_url)
             .with(headers: { 'Authorization' => "Bearer #{api_key}", 'Content-Type' => 'application/json' }) do |request|
        body = JSON.parse(request.body)
        body.keys.sort == %w[model questions state] &&
          body['model'] == model &&
          body['questions'] == questions &&
          body['state'] == state
      end.to_return(status: 200, body: { answers: { intent: { choice: 'stock' } }, meta: { latency: 12 } }.to_json)

      result = call

      expect(stub).to have_been_requested
      expect(result).to include(ok: true, error_reason: nil, model: model, api_mode: 'openrouter_decisions')
      # Only the answers payload survives — never the rest of the body.
      expect(result[:payload]).to eq('intent' => { 'choice' => 'stock' })
      expect(result[:payload]).to be_frozen
      expect(result.to_s).not_to include(api_key)
    end

    it 'defaults a missing state to an empty object' do
      stub = stub_request(:post, decisions_url) do |request|
        JSON.parse(request.body)['state'] == {}
      end.to_return(status: 200, body: { answers: { intent: { choice: 'stock' } } }.to_json)

      expect(call(questions: questions)).to include(ok: true)
      expect(stub).to have_been_requested
    end
  end

  describe '#call failure mapping' do
    it 'maps a non-2xx response to provider_error without echoing the body or key' do
      stub_request(:post, decisions_url).to_return(status: 401, body: "auth failed for #{api_key}")

      result = call

      expect(result).to include(ok: false, error_reason: 'provider_error')
      expect(result.to_s).not_to include(api_key)
      expect(result.to_s).not_to include('auth failed')
    end

    it 'maps a 2xx provider error object to provider_error' do
      stub_request(:post, decisions_url).to_return(status: 200, body: { error: { message: 'decisions model rejected' } }.to_json)

      result = call

      expect(result).to include(ok: false, error_reason: 'provider_error')
      expect(result.to_s).not_to include('decisions model rejected')
    end

    it 'maps missing answers to malformed_response' do
      stub_request(:post, decisions_url).to_return(status: 200, body: { decisions: [] }.to_json)

      expect(call).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'maps an empty answers object to malformed_response' do
      stub_request(:post, decisions_url).to_return(status: 200, body: { answers: {} }.to_json)

      expect(call).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'maps a non-hash answers value to malformed_response' do
      stub_request(:post, decisions_url).to_return(status: 200, body: { answers: 'nope' }.to_json)

      expect(call).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'maps a single over-long answer string (per-string bound) to malformed_response' do
      stub_request(:post, decisions_url).to_return(status: 200, body: { answers: { intent: 'x' * (described_class::MAX_STRING_LENGTH + 1) } }.to_json)

      expect(call).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'maps many small in-bounds answers whose aggregate JSON exceeds MAX_ANSWERS_BYTES to malformed_response' do
      # Each value is under the per-string bound and the key count is within MAX_HASH_KEYS,
      # so only the aggregate MAX_ANSWERS_BYTES ceiling can reject this — a genuine separate path.
      chunk = 'a' * (described_class::MAX_STRING_LENGTH - 500)
      answers = (1..50).each_with_object({}) { |i, hash| hash["k#{i}"] = chunk }
      expect(answers.to_json.bytesize).to be > described_class::MAX_ANSWERS_BYTES
      expect(answers.keys.size).to be <= described_class::MAX_HASH_KEYS
      stub_request(:post, decisions_url).to_return(status: 200, body: { answers: answers }.to_json)

      expect(call).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'maps an over-large raw response body (pre-parse bound) to malformed_response' do
      stub_request(:post, decisions_url).to_return(status: 200, body: 'x' * (described_class::MAX_RESPONSE_BYTES + 1))

      expect(call).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'maps malformed and empty bodies to malformed_response' do
      stub_request(:post, decisions_url).to_return(status: 200, body: 'not-json{')
      expect(call).to include(ok: false, error_reason: 'malformed_response')

      stub_request(:post, decisions_url).to_return(status: 200, body: '')
      expect(call).to include(ok: false, error_reason: 'malformed_response')

      stub_request(:post, decisions_url).to_return(status: 200, body: '"scalar"')
      expect(call).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'maps a timeout to the timeout reason' do
      stub_request(:post, decisions_url).to_timeout

      expect(call).to include(ok: false, error_reason: 'timeout')
    end

    it 'maps a network error to provider_error and never leaks the key' do
      stub_request(:post, decisions_url).to_raise(SocketError.new("connection to #{api_key} refused"))

      result = call

      expect(result).to include(ok: false, error_reason: 'provider_error')
      expect(result.to_s).not_to include(api_key)
    end
  end

  describe 'request validation before the network' do
    it 'rejects non-hash / empty / oversized-cardinality questions without any request' do
      [nil, 'x', {}, (1..(described_class::MAX_QUESTIONS + 1)).each_with_object({}) { |i, h| h["q#{i}"] = { 'type' => 'choice' } }].each do |bad|
        expect(call(questions: bad, state: {})).to include(ok: false, error_reason: 'malformed_response')
      end
      expect(a_request(:post, decisions_url)).not_to have_been_made
    end

    it 'rejects a question value that exceeds the string bound' do
      expect(call(questions: { 'intent' => { 'instructions' => 'y' * (described_class::MAX_STRING_LENGTH + 1) } })).to(
        include(ok: false, error_reason: 'malformed_response')
      )
    end

    it 'rejects a non-hash state' do
      expect(call(questions: questions, state: 'nope')).to include(ok: false, error_reason: 'malformed_response')
    end

    it 'rejects unknown top-level request keys fail-closed without any network (defense in depth)' do
      expect(call(questions: questions, state: state, secret: 'leak', reply: 'hi')).to include(ok: false, error_reason: 'malformed_response')
      expect(a_request(:post, decisions_url)).not_to have_been_made
    end

    it 'rejects a duplicate canonical top-level request key fail-closed without any network' do
      expect(client.call('questions' => questions, :questions => questions)).to include(ok: false, error_reason: 'malformed_response')
      expect(a_request(:post, decisions_url)).not_to have_been_made
    end

    it 'does not mutate the caller request' do
      stub_request(:post, decisions_url).to_return(status: 200, body: { answers: { intent: { choice: 'stock' } } }.to_json)
      request = { questions: questions, state: state }
      original = Marshal.load(Marshal.dump(request))

      call(request)

      expect(request).to eq(original)
    end
  end
end
