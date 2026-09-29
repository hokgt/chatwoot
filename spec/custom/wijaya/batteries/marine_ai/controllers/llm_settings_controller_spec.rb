# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Marine::LlmSettings', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  # supervisor / marketing / sales are custom roles (account_user role: :agent +
  # custom_role_id); none carry 'administrator'. One custom-role example represents
  # all three, alongside the plain-agent example.
  let(:custom_role) { create(:custom_role, account: account, permissions: ['conversation_manage']) }
  let(:supervisor) { create(:user) }

  before do
    # CustomRole is Enterprise-only (stripped in CE); the custom-role example below is
    # tagged :enterprise, so this supervisor fixture is only needed when enterprise/ is present.
    create(:account_user, user: supervisor, account: account, role: :agent, custom_role: custom_role) if ChatwootApp.enterprise?
  end

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

    context 'when it is a plain agent' do
      it 'is not authorized to read provider settings' do
        get "/api/v1/accounts/#{account.id}/marine/llm_settings",
            headers: agent.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is a custom-role agent (supervisor/marketing/sales)', :enterprise do
      it 'is not authorized to read provider settings' do
        get "/api/v1/accounts/#{account.id}/marine/llm_settings",
            headers: supervisor.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when no Marine config records exist (not seeded from installation_config.yml)' do
      it 'returns safe defaults for both models without any MARINE_* InstallationConfig rows' do
        expect(InstallationConfig.where('name LIKE ?', 'MARINE_%')).to be_empty

        get "/api/v1/accounts/#{account.id}/marine/llm_settings",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        %i[decision_maker_config response_generator_config].each do |key|
          expect(json_response[key][:provider]).to eq('openai')
          expect(json_response[key][:model]).to eq('gpt-4.1-mini')
          expect(json_response[key][:api_endpoint]).to eq('https://api.openai.com')
          expect(json_response[key][:api_key_present]).to be(false)
          expect(json_response[key][:configured]).to be(false)
        end
        expect(json_response[:available_providers]).to be_an(Array)
      end
    end

    context 'when only legacy settings exist' do
      before do
        set_config('MARINE_LLM_PROVIDER', 'openrouter')
        set_config('MARINE_OPEN_AI_API_KEY', 'sk-or-1234567890abcd')
        set_config('MARINE_OPEN_AI_MODEL', 'nvidia/nemotron')
      end

      it 'populates the response generator and, via fallback, the decision maker with masked keys' do
        get "/api/v1/accounts/#{account.id}/marine/llm_settings",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        %i[decision_maker_config response_generator_config].each do |key|
          expect(json_response[key][:provider]).to eq('openrouter')
          expect(json_response[key][:api_key_present]).to be(true)
          expect(json_response[key][:api_key_masked]).to eq('sk-or-...abcd')
        end
        expect(response.body).not_to include('sk-or-1234567890abcd')
      end
    end

    context 'when the two models are configured independently' do
      before do
        set_config('MARINE_LLM_PROVIDER', 'openrouter')
        set_config('MARINE_OPEN_AI_API_KEY', 'sk-or-response-key-99')
        set_config('MARINE_DECISION_LLM_PROVIDER', 'gemini')
        set_config('MARINE_DECISION_LLM_MODEL', 'gemini-2.5-flash')
        set_config('MARINE_DECISION_LLM_API_KEY', 'gem-decision-key-77')
      end

      it 'returns each model with its own provider and masked key' do
        get "/api/v1/accounts/#{account.id}/marine/llm_settings",
            headers: admin.create_new_auth_token,
            as: :json

        expect(json_response[:decision_maker_config][:provider]).to eq('gemini')
        expect(json_response[:decision_maker_config][:model]).to eq('gemini-2.5-flash')
        expect(json_response[:response_generator_config][:provider]).to eq('openrouter')
        expect(response.body).not_to include('gem-decision-key-77')
        expect(response.body).not_to include('sk-or-response-key-99')
      end
    end
  end

  describe 'PUT /api/v1/accounts/{account.id}/marine/llm_settings' do
    context 'when it is an agent' do
      it 'is not authorized' do
        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: { response_generator_config: { provider: 'gemini' } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'persists the response generator to the legacy runtime keys' do
        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: { response_generator_config: {
              provider: 'gemini', model: 'gemini-2.0-flash',
              api_endpoint: 'https://generativelanguage.googleapis.com/v1beta/openai', api_key: 'gem-secret-key-123'
            } },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(InstallationConfig.find_by(name: 'MARINE_LLM_PROVIDER').value).to eq('gemini')
        expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_MODEL').value).to eq('gemini-2.0-flash')
        expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_ENDPOINT').value).to eq('https://generativelanguage.googleapis.com/v1beta/openai')
        expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_API_KEY').value).to eq('gem-secret-key-123')
        expect(response.body).not_to include('gem-secret-key-123')
      end

      it 'persists the decision maker to its own keys without touching runtime keys' do
        set_config('MARINE_LLM_PROVIDER', 'openrouter')
        set_config('MARINE_OPEN_AI_MODEL', 'nvidia/nemotron')
        set_config('MARINE_OPEN_AI_API_KEY', 'sk-or-runtime-key-9')

        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: { decision_maker_config: {
              provider: 'gemini', model: 'gemini-2.5-flash', api_key: 'gem-decision-key-456'
            } },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(InstallationConfig.find_by(name: 'MARINE_DECISION_LLM_PROVIDER').value).to eq('gemini')
        expect(InstallationConfig.find_by(name: 'MARINE_DECISION_LLM_API_KEY').value).to eq('gem-decision-key-456')
        # Runtime keys unchanged — decision maker is not wired into the runner.
        expect(InstallationConfig.find_by(name: 'MARINE_LLM_PROVIDER').value).to eq('openrouter')
        expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_API_KEY').value).to eq('sk-or-runtime-key-9')
      end

      it 'keeps each existing key when its api_key is blank, independently' do
        set_config('MARINE_OPEN_AI_API_KEY', 'sk-response-existing-9999')
        set_config('MARINE_DECISION_LLM_API_KEY', 'gem-decision-existing-7777')

        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: {
              response_generator_config: { provider: 'openai', model: 'gpt-4.1-mini', api_key: '' },
              decision_maker_config: { provider: 'gemini', api_key: '' }
            },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_API_KEY').value).to eq('sk-response-existing-9999')
        expect(InstallationConfig.find_by(name: 'MARINE_DECISION_LLM_API_KEY').value).to eq('gem-decision-existing-7777')
      end

      it 'preserves an existing embedding configuration it never writes' do
        set_config('MARINE_EMBEDDING_MODEL', 'text-embedding-3-large')

        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: { response_generator_config: { provider: 'openai', model: 'gpt-4.1-mini' } },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(InstallationConfig.find_by(name: 'MARINE_EMBEDDING_MODEL').value).to eq('text-embedding-3-large')
      end

      it 'seeds the decision maker key from the fallback and keeps it after a same-request response change' do
        set_config('MARINE_OPEN_AI_API_KEY', 'sk-legacy-fallback-1')

        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: {
              # No decision key supplied; the response key is rotated in the SAME request.
              decision_maker_config: { provider: 'gemini' },
              response_generator_config: { api_key: 'sk-rotated-2' }
            },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        # The decision maker seeds from the OLD fallback (written before the response), not the new key.
        expect(InstallationConfig.find_by(name: 'MARINE_DECISION_LLM_API_KEY').value).to eq('sk-legacy-fallback-1')
        expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_API_KEY').value).to eq('sk-rotated-2')
      end

      it 'rejects an unknown provider with 422 without persisting anything' do
        set_config('MARINE_OPEN_AI_API_KEY', 'sk-response-existing-9999')

        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: { response_generator_config: { provider: 'not-a-provider', api_key: 'sk-new-key' } },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(InstallationConfig.find_by(name: 'MARINE_LLM_PROVIDER')).to be_nil
        expect(InstallationConfig.find_by(name: 'MARINE_OPEN_AI_API_KEY').value).to eq('sk-response-existing-9999')
      end

      it 'rejects a malformed nested payload with 422, not a 500' do
        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: { response_generator_config: 'gemini' },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it 'rolls back a valid target when the other target is invalid (atomic)' do
        put "/api/v1/accounts/#{account.id}/marine/llm_settings",
            params: {
              decision_maker_config: { provider: 'gemini', api_key: 'gem-decision-key-456' },
              response_generator_config: { provider: 'not-a-provider' }
            },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        # The valid decision-maker write must not have persisted.
        expect(InstallationConfig.find_by(name: 'MARINE_DECISION_LLM_PROVIDER')).to be_nil
        expect(InstallationConfig.find_by(name: 'MARINE_DECISION_LLM_API_KEY')).to be_nil
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/llm_settings/test' do
    context 'when it is an agent' do
      it 'is not authorized' do
        post "/api/v1/accounts/#{account.id}/marine/llm_settings/test",
             params: { target: 'response_generator', config: { provider: 'openai', api_key: 'sk-test' } },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'tests the decision maker with its submitted config' do
        service = instance_double(Marine::Llm::ConnectionTestService, call: { ok: true, message: 'pong', error: nil })
        expect(Marine::Llm::ConnectionTestService).to receive(:new)
          .with(hash_including(provider: 'gemini', api_key: 'gem-test-123', model: 'gemini-2.5-flash'))
          .and_return(service)

        post "/api/v1/accounts/#{account.id}/marine/llm_settings/test",
             params: { target: 'decision_maker', config: { provider: 'gemini', api_key: 'gem-test-123', model: 'gemini-2.5-flash' } },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:ok]).to be(true)
      end

      it 'falls back to the stored key for that target when the submitted key is blank' do
        set_config('MARINE_DECISION_LLM_API_KEY', 'gem-stored-decision-key')

        service = instance_double(Marine::Llm::ConnectionTestService, call: { ok: true, message: 'pong', error: nil })
        expect(Marine::Llm::ConnectionTestService).to receive(:new)
          .with(hash_including(api_key: 'gem-stored-decision-key'))
          .and_return(service)

        post "/api/v1/accounts/#{account.id}/marine/llm_settings/test",
             params: { target: 'decision_maker', config: { provider: 'gemini', api_key: '' } },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
      end

      it 'rejects a missing or invalid target with 422' do
        post "/api/v1/accounts/#{account.id}/marine/llm_settings/test",
             params: { config: { provider: 'openai', api_key: 'sk-test' } },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response[:ok]).to be(false)

        post "/api/v1/accounts/#{account.id}/marine/llm_settings/test",
             params: { target: 'bogus', config: { provider: 'openai', api_key: 'sk-test' } },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it 'rejects an unknown provider on test with 422 and never builds the service' do
        expect(Marine::Llm::ConnectionTestService).not_to receive(:new)

        post "/api/v1/accounts/#{account.id}/marine/llm_settings/test",
             params: { target: 'decision_maker', config: { provider: 'not-a-provider', api_key: 'sk-test' } },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response[:ok]).to be(false)
      end
    end
  end
end
