# frozen_string_literal: true

require 'rails_helper'

# The Marine Inboxes area (assistant<->inbox associations) is administrator-only.
# Every action — including the read-only index — must reject non-administrators so
# the sidebar/route hiding cannot be bypassed by calling the API directly.
#
# Role representation: administrators have account_user.role == :administrator.
# supervisor / marketing / sales are NOT distinct DB roles — they are custom roles,
# i.e. an account_user with role: :agent plus a custom_role_id. None of them ever
# carry the 'administrator' permission, so a single custom-role example represents
# all three; the plain agent example covers the no-custom-role case.
RSpec.describe 'Api::V1::Accounts::Marine::Inboxes', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:assistant) { create(:marine_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }

  let(:custom_role) { create(:custom_role, account: account, permissions: ['conversation_manage']) }
  let(:supervisor) { create(:user) }

  before do
    create(:account_user, user: supervisor, account: account, role: :agent, custom_role: custom_role)
  end

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/marine/assistants/{assistant.id}/inboxes' do
    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/inboxes"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is a plain agent' do
      it 'is not authorized' do
        get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/inboxes",
            headers: agent.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is a custom-role agent (supervisor/marketing/sales)' do
      it 'is not authorized' do
        get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/inboxes",
            headers: supervisor.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'returns the linked inboxes' do
        assistant.marine_inboxes.create!(inbox: inbox)

        get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/inboxes",
            headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].map { |i| i[:id] }).to include(inbox.id)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/assistants/{assistant.id}/inboxes' do
    context 'when it is a plain agent' do
      it 'is not authorized and creates no association' do
        expect do
          post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/inboxes",
               params: { inbox: { inbox_id: inbox.id } },
               headers: agent.create_new_auth_token, as: :json
        end.not_to change(MarineInbox, :count)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is a custom-role agent' do
      it 'is not authorized' do
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/inboxes",
             params: { inbox: { inbox_id: inbox.id } },
             headers: supervisor.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'links the inbox to the assistant' do
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/inboxes",
             params: { inbox: { inbox_id: inbox.id } },
             headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:created)
        expect(assistant.reload.inboxes).to include(inbox)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/marine/assistants/{assistant.id}/inboxes/{inbox_id}' do
    before { assistant.marine_inboxes.create!(inbox: inbox) }

    context 'when it is a plain agent' do
      it 'is not authorized and keeps the association' do
        delete "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/inboxes/#{inbox.id}",
               headers: agent.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unauthorized)
        expect(assistant.reload.inboxes).to include(inbox)
      end
    end

    context 'when it is an admin' do
      it 'removes the association' do
        delete "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/inboxes/#{inbox.id}",
               headers: admin.create_new_auth_token, as: :json
        expect(response).to have_http_status(:no_content)
        expect(assistant.reload.inboxes).not_to include(inbox)
      end
    end
  end
end
