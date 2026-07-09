# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Marine::CustomTools', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/marine/custom_tools' do
    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        get "/api/v1/accounts/#{account.id}/marine/custom_tools"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns success and lists tools (read access, no feature gate)' do
        create_list(:marine_custom_tool, 3, account: account)
        get "/api/v1/accounts/#{account.id}/marine/custom_tools",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].length).to eq(3)
      end

      it 'does not expose auth_config to agents' do
        create(:marine_custom_tool, :with_bearer_auth, account: account)
        get "/api/v1/accounts/#{account.id}/marine/custom_tools",
            headers: agent.create_new_auth_token,
            as: :json

        expect(json_response[:payload].first).not_to have_key(:auth_config)
      end
    end

    context 'when it is an admin' do
      it 'returns all tools including disabled ones' do
        create(:marine_custom_tool, account: account, enabled: true)
        create(:marine_custom_tool, account: account, enabled: false)
        get "/api/v1/accounts/#{account.id}/marine/custom_tools",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].length).to eq(2)
      end

      it 'exposes auth_config to admins' do
        create(:marine_custom_tool, :with_bearer_auth, account: account)
        get "/api/v1/accounts/#{account.id}/marine/custom_tools",
            headers: admin.create_new_auth_token,
            as: :json

        expect(json_response[:payload].first[:auth_config]).to eq({ token: 'test_bearer_token_123' })
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/marine/custom_tools/{id}' do
    let(:custom_tool) { create(:marine_custom_tool, account: account) }

    context 'when it is an agent' do
      it 'returns success status and custom tool' do
        get "/api/v1/accounts/#{account.id}/marine/custom_tools/#{custom_tool.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:id]).to eq(custom_tool.id)
        expect(json_response[:title]).to eq(custom_tool.title)
      end
    end

    context 'when custom tool does not exist' do
      it 'returns not found status' do
        get "/api/v1/accounts/#{account.id}/marine/custom_tools/999999",
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/custom_tools' do
    let(:valid_attributes) do
      {
        custom_tool: {
          title: 'Fetch Order Status',
          description: 'Fetches order status from external API',
          endpoint_url: 'https://api.example.com/orders/{{ order_id }}',
          http_method: 'GET',
          enabled: true,
          param_schema: [
            { name: 'order_id', type: 'string', description: 'The order ID', required: true }
          ]
        }
      }
    end

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        post "/api/v1/accounts/#{account.id}/marine/custom_tools",
             params: valid_attributes,
             headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'creates a new custom tool and returns success status' do
        post "/api/v1/accounts/#{account.id}/marine/custom_tools",
             params: valid_attributes,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:title]).to eq('Fetch Order Status')
        expect(json_response[:enabled]).to be(true)
        expect(json_response[:slug]).to eq('custom_fetch_order_status')
        expect(json_response[:param_schema]).to eq([
                                                     { name: 'order_id', type: 'string', description: 'The order ID', required: true }
                                                   ])
      end

      context 'with invalid parameters' do
        it 'returns unprocessable entity status' do
          post "/api/v1/accounts/#{account.id}/marine/custom_tools",
               params: { custom_tool: { title: '', endpoint_url: '' } },
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_entity)
        end
      end

      context 'with invalid endpoint URL' do
        it 'returns unprocessable entity status' do
          post "/api/v1/accounts/#{account.id}/marine/custom_tools",
               params: { custom_tool: { title: 'Test Tool', endpoint_url: 'http://localhost/api', http_method: 'GET' } },
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_entity)
        end
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/marine/custom_tools/{id}' do
    let(:custom_tool) { create(:marine_custom_tool, account: account) }
    let(:update_attributes) { { custom_tool: { title: 'Updated Tool Title', enabled: false } } }

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        patch "/api/v1/accounts/#{account.id}/marine/custom_tools/#{custom_tool.id}",
              params: update_attributes,
              headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'updates the custom tool and returns success status' do
        patch "/api/v1/accounts/#{account.id}/marine/custom_tools/#{custom_tool.id}",
              params: update_attributes,
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:title]).to eq('Updated Tool Title')
        expect(json_response[:enabled]).to be(false)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/marine/custom_tools/{id}' do
    let!(:custom_tool) { create(:marine_custom_tool, account: account) }

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        delete "/api/v1/accounts/#{account.id}/marine/custom_tools/#{custom_tool.id}",
               headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'deletes the custom tool and returns no content status' do
        expect do
          delete "/api/v1/accounts/#{account.id}/marine/custom_tools/#{custom_tool.id}",
                 headers: admin.create_new_auth_token
        end.to change(Marine::CustomTool, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end
    end
  end
end
