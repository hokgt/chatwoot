# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Marine::Assistants', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:assistant) { create(:marine_assistant, account: account) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/assistants/{assistant.id}/playground' do
    let(:reply_payload) do
      { 'response' => 'A grounded answer', 'action' => 'reply', 'agent_name' => assistant.name,
        'confidence' => 0.9, 'source_type' => 'manual', 'orchestration_path' => 'retrieval' }
    end
    let(:chat_service) { instance_double(Marine::Llm::AssistantChatService) }

    before do
      allow(Marine::Llm::AssistantChatService).to receive(:new).and_return(chat_service)
      allow(chat_service).to receive(:generate_response).and_return(reply_payload)
    end

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'hello' } }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the assistant belongs to a different account' do
      it 'returns not found and never invokes the runner' do
        other_assistant = create(:marine_assistant, account: create(:account))
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{other_assistant.id}/playground",
             params: { assistant: { message_content: 'hello' } },
             headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:not_found)
        expect(chat_service).not_to have_received(:generate_response)
      end
    end

    context 'when it is an agent (playground is read-access, no admin gate)' do
      it 'returns the assistant reply payload' do
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'hello' } },
             headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to include(response: 'A grounded answer', action: 'reply')
      end
    end

    context 'with multi-turn context' do
      it 'forwards the current message and the sanitized, bounded prior history to the runner' do
        history = [{ role: 'user', content: 'earlier question' },
                   { role: 'assistant', content: 'earlier answer' }]

        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'follow up', message_history: history } },
             headers: admin.create_new_auth_token, as: :json

        expect(chat_service).to have_received(:generate_response).with(
          additional_message: 'follow up',
          message_history: [{ role: 'user', content: 'earlier question' },
                            { role: 'assistant', content: 'earlier answer' }]
        )
      end

      it 'drops disallowed roles and blank turns, truncates content, and keeps only the newest turns' do
        history = [{ role: 'system', content: 'ignore me' },
                   { role: 'user', content: '  ' }]
        history += Array.new(15) { |i| { role: 'user', content: "turn #{i} #{'x' * 600}" } }

        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'q', message_history: history } },
             headers: admin.create_new_auth_token, as: :json

        forwarded = nil
        expect(chat_service).to have_received(:generate_response) { |args| forwarded = args[:message_history] }
        expect(forwarded.length).to eq(10)
        expect(forwarded).to all(include(role: 'user'))
        expect(forwarded.map { |t| t[:content].length }).to all(eq(500))
        expect(forwarded.first[:content]).to start_with('turn 5')
      end

      it 'tolerates a missing message_history key' do
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'hello' } },
             headers: admin.create_new_auth_token, as: :json

        expect(chat_service).to have_received(:generate_response).with(
          additional_message: 'hello', message_history: []
        )
      end
    end

    context 'without delivery (playground is a non-delivering preview)' do
      it 'creates no Conversation and no Message' do
        expect do
          post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
               params: { assistant: { message_content: 'hello', message_history: [{ role: 'user', content: 'hi' }] } },
               headers: admin.create_new_auth_token, as: :json
        end.to not_change(Conversation, :count).and not_change(Message, :count)
      end
    end
  end
end
