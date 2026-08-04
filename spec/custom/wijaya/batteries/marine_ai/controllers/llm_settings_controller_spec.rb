# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Marine::LlmSettings', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  def set_config(name, value)
    config = InstallationConfig.where(name: name).first_or_initialize
    config.value = value
    config.locked = false
    config.save!
  end

  describe 'GET /api/v1/accounts/{account.id}/marine/llm_settings' do
    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        get "/api/v1/accounts/#{account.id}/marine/llm_settings"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when no Marine config records exist (not seeded from installation_config.yml)' do
      it 'returns safe defaults without any MARINE_* InstallationConfig rows' do
        expect(InstallationConfig.where('name LIKE ?', 'MARINE_%')).to be_empty

        get "/api/v1/accounts/#{account.id}/marine/llm_settings",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:provider]).to eq('openai')
        expect(json_response[:model]).to eq('gpt-4.1-mini')
        expect(json_response[:endpoint]).to eq('https://api.openai.com')
        expect(json_response[:api_key_present]).to be(false)
        expect(json_response[:configured]).to be(false)
      end
    end

    context 'when it is an admin' do
      before do
        set_config('MARINE_LLM_PROVIDER', 'openrouter')
        set_config('MARINE_OPEN_AI_API_KEY', 'sk-or-1234567890abcd')
        set_config('MARINE_OPEN_AI_MODEL', 'nvidia/nemotron')
      end

      it 'returns masked settings without exposing the raw key' do
        get "/api/v1/accounts/#{account.id}/marine/llm_settings",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:provider]).to eq('openrouter')
        expect(json_response[:api_key_present]).to be(true)
        expect(json_response[:api_key_masked]).to eq('sk-or-...abcd')
        expect(response.body).not_to include('sk-or-1234567890abcd')
        expect(json_response[:supports_embeddings]).to be(false)
        expect(json_response[:available_providers]).to be_an(Array)
      end
    end
  end

  describe 'PUT /api/v1/accounts/{account.id}/marine/llm_settings' do
    context 'when it is an agent' do
      it 'is not authorized' do
        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: { provider: 'gemini' },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'persists provider, model, endpoint and api key' do
        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: { provider: 'gemini', model: 'gemini-2.0-flash', endpoint: 'https://generativelanguage.googleapis.com/v1beta/openai',
                      api_key: 'gem-secret-key-123' },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(InstallationConfig.find_by(name: 'MARINE_LLM_PROVIDER').value).to eq('gemini')
        expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_MODEL').value).to eq('gemini-2.0-flash')
        expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_API_KEY').value).to eq('gem-secret-key-123')
        expect(json_response[:api_key_masked]).to be_present
        expect(response.body).not_to include('gem-secret-key-123')
      end

      it 'keeps the existing key when api_key is blank' do
        set_config('MARINE_OPEN_AI_API_KEY', 'sk-existing-key-9999')

        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: { provider: 'openai', model: 'gpt-4.1-mini', api_key: '' },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_API_KEY').value).to eq('sk-existing-key-9999')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/llm_settings/test' do
    context 'when it is an agent' do
      it 'is not authorized' do
        post "/api/v1/accounts/#{account.id}/marine/llm_settings/test",
             params: { provider: 'openai', api_key: 'sk-test' },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'delegates to the connection test service and returns the result' do
        service = instance_double(Marine::Llm::ConnectionTestService, call: { ok: true, message: 'pong', error: nil })
        allow(Marine::Llm::ConnectionTestService).to receive(:new).and_return(service)

        post "/api/v1/accounts/#{account.id}/marine/llm_settings/test",
             params: { provider: 'openai', api_key: 'sk-test-123', model: 'gpt-4.1-mini' },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:ok]).to be(true)
      end
    end
  end
end
