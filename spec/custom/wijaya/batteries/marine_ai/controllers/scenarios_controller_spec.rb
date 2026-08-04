# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Marine::Scenarios', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:assistant) { create(:marine_assistant, account: account) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/marine/assistants/{assistant.id}/scenarios' do
    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns success and lists scenarios (read access, no feature gate)' do
        create_list(:marine_scenario, 3, assistant: assistant, account: account)
        get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].length).to eq(3)
      end
    end

    context 'when it is an admin' do
      it 'returns only enabled scenarios' do
        create(:marine_scenario, assistant: assistant, account: account, enabled: true)
        create(:marine_scenario, assistant: assistant, account: account, enabled: false)
        get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].length).to eq(1)
        expect(json_response[:payload].first[:enabled]).to be(true)
      end
    end

    context 'when the assistant belongs to a different account' do
      it 'returns not found status' do
        other_account = create(:account)
        other_assistant = create(:marine_assistant, account: other_account)
        get "/api/v1/accounts/#{account.id}/marine/assistants/#{other_assistant.id}/scenarios",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/marine/assistants/{assistant.id}/scenarios/{id}' do
    let(:scenario) { create(:marine_scenario, assistant: assistant, account: account) }

    context 'when it is an agent' do
      it 'returns success status and scenario' do
        get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios/#{scenario.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:id]).to eq(scenario.id)
        expect(json_response[:title]).to eq(scenario.title)
      end
    end

    context 'when scenario does not exist' do
      it 'returns not found status' do
        get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios/999999",
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/assistants/{assistant.id}/scenarios' do
    let(:valid_attributes) do
      {
        scenario: {
          title: 'Test Scenario',
          description: 'Test description',
          instruction: 'Respond politely to the customer',
          enabled: true
        }
      }
    end

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios",
             params: valid_attributes,
             headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'creates a new scenario and returns success status' do
        expect do
          post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios",
               params: valid_attributes,
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Marine::Scenario, :count).by(1)

        expect(response).to have_http_status(:success)
        expect(json_response[:title]).to eq('Test Scenario')
        expect(json_response[:enabled]).to be(true)
        expect(json_response[:assistant_id]).to eq(assistant.id)
        expect(json_response[:account_id]).to eq(account.id)
      end

      it 'accepts valid custom tool references and resolves them into tools' do
        create(:marine_custom_tool, account: account, slug: 'custom_fetch-order')
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios",
             params: { scenario: { title: 'Order flow', description: 'Handles orders',
                                   instruction: 'Use [@Fetch Order](tool://custom_fetch-order)' } },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:tools]).to eq(['custom_fetch-order'])
      end

      context 'with invalid parameters' do
        it 'returns unprocessable entity status' do
          post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios",
               params: { scenario: { title: '', description: '', instruction: '' } },
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_entity)
        end
      end

      context 'with an invalid tool reference' do
        it 'returns unprocessable entity status' do
          post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios",
               params: { scenario: { title: 'Bad', description: 'Bad tool',
                                     instruction: 'Use [@Unknown](tool://unknown_tool)' } },
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_entity)
          expect(json_response[:message]).to include('invalid tools: unknown_tool')
        end
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/marine/assistants/{assistant.id}/scenarios/{id}' do
    let(:scenario) { create(:marine_scenario, assistant: assistant, account: account) }
    let(:update_attributes) { { scenario: { title: 'Updated Scenario Title', enabled: false } } }

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        patch "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios/#{scenario.id}",
              params: update_attributes,
              headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'updates the scenario and returns success status' do
        patch "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios/#{scenario.id}",
              params: update_attributes,
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:title]).to eq('Updated Scenario Title')
        expect(json_response[:enabled]).to be(false)
      end

      context 'with invalid parameters' do
        it 'returns unprocessable entity status' do
          patch "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios/#{scenario.id}",
                params: { scenario: { title: '' } },
                headers: admin.create_new_auth_token,
                as: :json

          expect(response).to have_http_status(:unprocessable_entity)
        end
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/marine/assistants/{assistant.id}/scenarios/{id}' do
    let!(:scenario) { create(:marine_scenario, assistant: assistant, account: account) }

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        delete "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios/#{scenario.id}",
               headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'deletes the scenario and returns no content status' do
        expect do
          delete "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios/#{scenario.id}",
                 headers: admin.create_new_auth_token
        end.to change(Marine::Scenario, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end

      context 'when scenario does not exist' do
        it 'returns not found status' do
          delete "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/scenarios/999999",
                 headers: admin.create_new_auth_token

          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end
end
