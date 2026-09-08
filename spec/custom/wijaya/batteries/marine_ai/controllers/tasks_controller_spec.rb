# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Marine Tasks API', type: :request do
  let!(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let!(:conversation) { create(:conversation, account: account) }

  describe 'POST /api/v1/accounts/{account.id}/marine/tasks/rewrite' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/marine/tasks/rewrite", params: { content: 'hi', operation: 'improve' }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the Marine LLM is not configured' do
      it 'degrades safely with an error and never raises' do
        post "/api/v1/accounts/#{account.id}/marine/tasks/rewrite",
             headers: agent.create_new_auth_token,
             params: { content: 'please fix this', operation: 'improve' },
             as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq('Marine LLM is not configured')
      end
    end

    context 'when the operation is invalid' do
      it 'returns a validation error' do
        post "/api/v1/accounts/#{account.id}/marine/tasks/rewrite",
             headers: agent.create_new_auth_token,
             params: { content: 'hi', operation: 'nonsense' },
             as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq('invalid_operation')
      end
    end

    context 'when Marine returns a rewritten message' do
      it 'renders the message with follow-up context' do
        allow_any_instance_of(Marine::Copilot::RewriteService).to receive(:perform).and_return(
          message: 'Improved text', error: nil, follow_up_context: { event_name: 'improve' }
        )

        post "/api/v1/accounts/#{account.id}/marine/tasks/rewrite",
             headers: agent.create_new_auth_token,
             params: { content: 'raw', operation: 'improve' },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['message']).to eq('Improved text')
        expect(response.parsed_body['follow_up_context']).to include('event_name' => 'improve')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/tasks/reply_suggestion' do
    it 'passes the conversation to the Marine reply suggestion service' do
      allow_any_instance_of(Marine::Copilot::ReplySuggestionService).to receive(:perform).and_return(
        message: 'Suggested reply', error: nil
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id },
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Suggested reply')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/tasks/summarize' do
    it 'returns the Marine-generated summary' do
      allow_any_instance_of(Marine::Copilot::SummaryService).to receive(:perform).and_return(
        message: 'Conversation summary', error: nil, follow_up_context: { event_name: 'summarize' }
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/summarize",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id },
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Conversation summary')
      expect(response.parsed_body['follow_up_context']).to include('event_name' => 'summarize')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/tasks/translate' do
    it 'returns the translated content' do
      allow_any_instance_of(Marine::Copilot::TranslateService).to receive(:perform).and_return(
        message: 'Halo dunia', error: nil
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/translate",
           headers: agent.create_new_auth_token,
           params: { content: 'Hello world', target_language: 'id' },
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Halo dunia')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/tasks/follow_up' do
    it 'returns the refined message' do
      allow_any_instance_of(Marine::Copilot::FollowUpService).to receive(:perform).and_return(
        message: 'Shorter reply', error: nil, follow_up_context: { event_name: 'improve' }
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: { follow_up_context: { event_name: 'improve' }, message: 'make it shorter' },
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Shorter reply')
    end
  end
end
