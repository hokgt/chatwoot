# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Marine::CopilotThreads', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:assistant) { create(:marine_assistant, account: account) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  before { allow(Marine::Llm::Config).to receive(:configured?).and_return(false) }

  describe 'GET index' do
    it 'returns unauthorized for an anonymous user' do
      get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/copilot_threads"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'lists only the current user threads' do
      create(:marine_copilot_thread, account: account, assistant: assistant, user: admin)
      create(:marine_copilot_thread, account: account, assistant: assistant, user: agent)

      get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/copilot_threads",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:payload].length).to eq(1)
    end
  end

  describe 'POST create' do
    it 'creates a thread with a user message and a synchronous assistant answer' do
      post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/copilot_threads",
           params: { message: 'Which conversations mention refunds?' },
           headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:created)
      types = json_response[:messages].map { |m| m[:message_type] }
      expect(types).to eq(%w[user assistant])
      expect(json_response[:title]).to be_present
    end

    it 'rejects a blank message' do
      post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/copilot_threads",
           params: { message: '' },
           headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'cross-account isolation' do
    it 'does not expose an assistant from another account' do
      other_assistant = create(:marine_assistant, account: create(:account))

      get "/api/v1/accounts/#{account.id}/marine/assistants/#{other_assistant.id}/copilot_threads",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'does not expose another user thread on show' do
      thread = create(:marine_copilot_thread, account: account, assistant: assistant, user: agent)

      get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/copilot_threads/#{thread.id}",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
