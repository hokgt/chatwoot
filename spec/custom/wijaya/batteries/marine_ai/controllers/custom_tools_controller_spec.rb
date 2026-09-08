# frozen_string_literal: true

require 'rails_helper'

# Marine custom tools have been removed to eliminate all direct outbound
# connectivity between Marine AI and ERP. The routes are gone and every action
# returns 404, so no custom-tool API surface remains reachable for any user.
RSpec.describe 'Api::V1::Accounts::Marine::CustomTools', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  describe 'GET /api/v1/accounts/{account.id}/marine/custom_tools' do
    it 'returns not found for an un-authenticated user' do
      get "/api/v1/accounts/#{account.id}/marine/custom_tools"
      expect(response).to have_http_status(:not_found)
    end

    it 'returns not found for an agent' do
      get "/api/v1/accounts/#{account.id}/marine/custom_tools",
          headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'returns not found for an admin' do
      get "/api/v1/accounts/#{account.id}/marine/custom_tools",
          headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/marine/custom_tools/{id}' do
    it 'returns not found for an agent' do
      get "/api/v1/accounts/#{account.id}/marine/custom_tools/1",
          headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'returns not found for an admin' do
      get "/api/v1/accounts/#{account.id}/marine/custom_tools/1",
          headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/custom_tools' do
    let(:attributes) { { custom_tool: { title: 'Fetch Order Status', endpoint_url: 'https://api.example.com/orders' } } }

    it 'returns not found for an agent' do
      post "/api/v1/accounts/#{account.id}/marine/custom_tools",
           params: attributes, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'returns not found for an admin' do
      post "/api/v1/accounts/#{account.id}/marine/custom_tools",
           params: attributes, headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/custom_tools/test' do
    it 'returns not found for an admin' do
      post "/api/v1/accounts/#{account.id}/marine/custom_tools/test",
           headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/marine/custom_tools/{id}' do
    it 'returns not found for an admin' do
      patch "/api/v1/accounts/#{account.id}/marine/custom_tools/1",
            params: { custom_tool: { title: 'Updated' } }, headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/marine/custom_tools/{id}' do
    it 'returns not found for an admin' do
      delete "/api/v1/accounts/#{account.id}/marine/custom_tools/1",
             headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
