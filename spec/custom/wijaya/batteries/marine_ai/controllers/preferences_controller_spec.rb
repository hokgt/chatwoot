# frozen_string_literal: true

require 'rails_helper'

# Marine preferences back the administrator-only Settings area. Both reading (show)
# and writing (update) must reject non-administrators.
#
# supervisor / marketing / sales are custom roles (account_user role: :agent +
# custom_role_id); none carry 'administrator'. A single custom-role example stands
# in for all three, alongside a plain-agent example.
RSpec.describe 'Api::V1::Accounts::Marine::Preferences', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  let(:custom_role) { create(:custom_role, account: account, permissions: ['conversation_manage']) }
  let(:supervisor) { create(:user) }

  before do
    create(:account_user, user: supervisor, account: account, role: :agent, custom_role: custom_role)
  end

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/marine/preferences' do
    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        get "/api/v1/accounts/#{account.id}/marine/preferences"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is a plain agent' do
      it 'is not authorized' do
        get "/api/v1/accounts/#{account.id}/marine/preferences",
            headers: agent.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is a custom-role agent (supervisor/marketing/sales)' do
      it 'is not authorized' do
        get "/api/v1/accounts/#{account.id}/marine/preferences",
            headers: supervisor.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'returns the marine preferences' do
        get "/api/v1/accounts/#{account.id}/marine/preferences",
            headers: admin.create_new_auth_token, as: :json
        expect(response).to have_http_status(:success)
        expect(json_response).to be_a(Hash)
      end
    end
  end

  describe 'PUT /api/v1/accounts/{account.id}/marine/preferences' do
    context 'when it is a plain agent' do
      it 'is not authorized' do
        put "/api/v1/accounts/#{account.id}/marine/preferences",
            params: { marine_features: { feature_faq: true } },
            headers: agent.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is a custom-role agent' do
      it 'is not authorized' do
        put "/api/v1/accounts/#{account.id}/marine/preferences",
            params: { marine_features: { feature_faq: true } },
            headers: supervisor.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'persists the preferences' do
        put "/api/v1/accounts/#{account.id}/marine/preferences",
            params: { marine_features: { feature_faq: false } },
            headers: admin.create_new_auth_token, as: :json
        expect(response).to have_http_status(:success)
      end
    end
  end
end
