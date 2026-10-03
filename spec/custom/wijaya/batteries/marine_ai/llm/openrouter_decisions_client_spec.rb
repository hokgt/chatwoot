# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::OpenrouterDecisionsClient do
  let(:api_key) { 'sk-or-decisions-secret-1234' }
  let(:decisions_url) { 'https://openrouter.ai/api/alpha/decisions' }

  describe '#decisions_url' do
    it 'derives the Decisions URL from the OpenRouter root' do
      client = described_class.new(api_key: api_key, endpoint: 'https://openrouter.ai')
      expect(client.decisions_url).to eq(decisions_url)
    end

    it 'derives the Decisions URL from the OpenRouter /api base without appending /v1' do
      client = described_class.new(api_key: api_key, endpoint: 'https://openrouter.ai/api')
      expect(client.decisions_url).to eq(decisions_url)
    end

    it 'accepts an explicit endpoint already ending /api/alpha/decisions' do
      client = described_class.new(api_key: api_key, endpoint: decisions_url)
      expect(client.decisions_url).to eq(decisions_url)
    end

    it 'ignores a trailing slash and falls back to the default base when blank' do
      expect(described_class.new(api_key: api_key, endpoint: 'https://openrouter.ai/api/').decisions_url).to eq(decisions_url)
      expect(described_class.new(api_key: api_key, endpoint: '').decisions_url).to eq(decisions_url)
    end
  end

  describe '#test_connection' do
    subject(:result) { described_class.new(api_key: api_key, endpoint: 'https://openrouter.ai/api', model: 'typesafe/jev-1.13').test_connection }

    it 'POSTs the documented model/questions/state contract with a bearer token and never leaks the key' do
      stub = stub_request(:post, decisions_url)
             .with(
               headers: { 'Authorization' => "Bearer #{api_key}", 'Content-Type' => 'application/json' }
             ) do |request|
        body = JSON.parse(request.body)
        question = body.dig('questions', 'connection_check')
        body['model'] == 'typesafe/jev-1.13' &&
          body['questions'].is_a?(Hash) &&
          question.is_a?(Hash) &&
          question['type'] == 'choice' &&
          question['instructions'].is_a?(String) && question['instructions'].present? &&
          question['criteria'].is_a?(Hash) && question['criteria'].keys.sort == %w[invalid reachable] &&
          body['state'] == { 'test_value' => 'ping' }
      end.to_return(status: 200, body: { answers: { connection_check: { type: 'choice', choice: 'reachable' } } }.to_json)

      expect(result[:ok]).to be(true)
      expect(stub).to have_been_requested
      expect(result.to_s).not_to include(api_key)
    end

    it 'treats a 2xx with valid non-empty JSON and no error object as success' do
      stub_request(:post, decisions_url).to_return(status: 200, body: { decisions: [] }.to_json)
      expect(result[:ok]).to be(true)
      expect(result[:error]).to be_nil
    end

    it 'fails on a non-2xx response without echoing the body or key' do
      stub_request(:post, decisions_url).to_return(status: 401, body: "auth failed for #{api_key}")
      expect(result[:ok]).to be(false)
      expect(result[:error]).to include('401')
      expect(result[:error]).not_to include(api_key)
    end

    it 'fails with a sanitized message on a provider error body' do
      stub_request(:post, decisions_url).to_return(
        status: 200, body: { error: { message: 'model is a decisions model' } }.to_json
      )
      expect(result[:ok]).to be(false)
      expect(result[:error]).to eq('model is a decisions model')
    end

    it 'fails on a bare non-object JSON scalar' do
      stub_request(:post, decisions_url).to_return(status: 200, body: '"ok"')
      expect(result[:ok]).to be(false)
      expect(result[:error]).to be_present
    end

    it 'fails on an empty JSON object' do
      stub_request(:post, decisions_url).to_return(status: 200, body: '{}')
      expect(result[:ok]).to be(false)
      expect(result[:error]).to be_present
    end

    it 'fails on malformed JSON' do
      stub_request(:post, decisions_url).to_return(status: 200, body: 'not-json{')
      expect(result[:ok]).to be(false)
      expect(result[:error]).to be_present
    end

    it 'fails on an empty body' do
      stub_request(:post, decisions_url).to_return(status: 200, body: '')
      expect(result[:ok]).to be(false)
      expect(result[:error]).to be_present
    end

    it 'fails on a timeout' do
      stub_request(:post, decisions_url).to_timeout
      expect(result[:ok]).to be(false)
      expect(result[:error]).to be_present
    end

    it 'redacts the API key from a raised network error message' do
      stub_request(:post, decisions_url).to_raise(StandardError.new("connection to #{api_key} refused"))
      expect(result[:ok]).to be(false)
      expect(result[:error]).not_to include(api_key)
      expect(result[:error]).to include('[REDACTED]')
    end
  end
end
