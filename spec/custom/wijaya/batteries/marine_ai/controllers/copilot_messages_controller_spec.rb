# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Marine::CopilotMessages', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:assistant) { create(:marine_assistant, account: account) }
  let(:thread) { create(:marine_copilot_thread, account: account, assistant: assistant, user: admin) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  before { allow(Marine::Llm::Config).to receive(:configured?).and_return(false) }

  describe 'GET index' do
    it 'returns the thread messages in order' do
      thread.copilot_messages.create!(message_type: :user, message: { content: 'hi' })

      get "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/copilot_threads/#{thread.id}/copilot_messages",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:payload].length).to eq(1)
    end
  end

  describe 'POST create' do
    it 'appends a user message and a synchronous assistant answer' do
      post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/copilot_threads/#{thread.id}/copilot_messages",
           params: { message: 'any refunds?' },
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:created)
      types = json_response[:payload].map { |m| m[:message_type] }
      expect(types).to eq(%w[user assistant])
    end
  end

  describe 'cross-user isolation' do
    it 'does not allow posting to another user thread' do
      post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/copilot_threads/#{thread.id}/copilot_messages",
           params: { message: 'sneaky' },
           headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
