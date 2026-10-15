# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/custom_roles/follow_up_provenance')

RSpec.describe 'Marine Tasks API', type: :request do
  let!(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let!(:conversation) { create(:conversation, account: account) }
  # Two conversations in another account so its second display_id is guaranteed
  # not to exist in `account` (cross-account fixture).
  let(:other_account) { create(:account) }
  let!(:other_conversations) { create_list(:conversation, 2, account: other_account) }

  def spy_service(service_class)
    service = instance_spy(service_class)
    allow(service_class).to receive(:new).and_return(service)
    service
  end

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
             params: { content: 'please fix this', operation: 'improve' }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq('Marine LLM is not configured')
      end
    end

    context 'when the operation is invalid' do
      it 'returns a validation error' do
        post "/api/v1/accounts/#{account.id}/marine/tasks/rewrite",
             headers: agent.create_new_auth_token,
             params: { content: 'hi', operation: 'nonsense' }, as: :json

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
             params: { content: 'raw', operation: 'improve' }, as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['message']).to eq('Improved text')
        expect(response.parsed_body['follow_up_context']).to include('event_name' => 'improve')
      end
    end

    context 'when a hidden conversation_display_id is supplied' do
      let!(:hidden_conversation) { create(:conversation, account: account) }

      it 'stays context-free and never resolves or authorizes the conversation' do
        service = instance_spy(Marine::Copilot::RewriteService, perform: { message: 'Improved text', error: nil })
        allow(Marine::Copilot::RewriteService).to receive(:new)
          .with(account: account, content: 'raw', operation: 'improve').and_return(service)

        post "/api/v1/accounts/#{account.id}/marine/tasks/rewrite",
             headers: agent.create_new_auth_token,
             params: { content: 'raw', operation: 'improve', conversation_display_id: hidden_conversation.display_id },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['message']).to eq('Improved text')
        expect(Marine::Copilot::RewriteService).to have_received(:new)
          .with(account: account, content: 'raw', operation: 'improve')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/tasks/reply_suggestion' do
    it 'returns unauthorized for an unauthenticated user' do
      post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns not found without invoking the service when the display id is missing' do
      spy_service(Marine::Copilot::ReplySuggestionService)

      [nil, ''].each do |display_id|
        post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
             headers: agent.create_new_auth_token,
             params: { conversation_display_id: display_id }, as: :json

        expect(response).to have_http_status(:not_found)
      end

      expect(Marine::Copilot::ReplySuggestionService).not_to have_received(:new)
    end

    it 'returns not found for a cross-account display id' do
      spy_service(Marine::Copilot::ReplySuggestionService)

      post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: other_conversations.last.display_id }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(Marine::Copilot::ReplySuggestionService).not_to have_received(:new)
    end

    it 'is unauthorized for an agent with neither inbox nor team access' do
      spy_service(Marine::Copilot::ReplySuggestionService)

      post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(Marine::Copilot::ReplySuggestionService).not_to have_received(:new)
      expect(response.parsed_body).not_to have_key('message')
      expect(response.parsed_body).not_to have_key('follow_up_context')
    end

    it 'passes the conversation to the Marine reply suggestion service for an administrator' do
      allow_any_instance_of(Marine::Copilot::ReplySuggestionService).to receive(:perform).and_return(
        message: 'Suggested reply', error: nil
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
           headers: administrator.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Suggested reply')
    end

    it 'returns the suggestion for an agent with inbox access' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      allow_any_instance_of(Marine::Copilot::ReplySuggestionService).to receive(:perform).and_return(
        message: 'Suggested reply', error: nil
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Suggested reply')
    end

    it 'returns the suggestion for an agent with team access' do
      team = create(:team, account: account)
      conversation.update!(team: team)
      create(:team_member, team: team, user: agent)
      allow_any_instance_of(Marine::Copilot::ReplySuggestionService).to receive(:perform).and_return(
        message: 'Suggested reply', error: nil
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Suggested reply')
    end

    describe 'custom roles' do
      let(:custom_agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, user: custom_agent, inbox: conversation.inbox)
      end

      it 'returns forbidden for a restrictive role without invoking the service' do
        custom_role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
        account.account_users.find_by(user_id: custom_agent.id).update!(custom_role: custom_role)
        spy_service(Marine::Copilot::ReplySuggestionService)

        post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
             headers: custom_agent.create_new_auth_token,
             params: { conversation_display_id: conversation.display_id }, as: :json

        expect(response).to have_http_status(:forbidden)
        expect(Marine::Copilot::ReplySuggestionService).not_to have_received(:new)
        expect(response.parsed_body).not_to have_key('message')
        expect(response.parsed_body).not_to have_key('follow_up_context')
      end

      it 'returns the suggestion for a conversation_manage role on an accessible inbox conversation' do
        custom_role = create(:custom_role, account: account, permissions: ['conversation_manage'])
        account.account_users.find_by(user_id: custom_agent.id).update!(custom_role: custom_role)
        allow_any_instance_of(Marine::Copilot::ReplySuggestionService).to receive(:perform).and_return(
          message: 'Suggested reply', error: nil
        )

        post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
             headers: custom_agent.create_new_auth_token,
             params: { conversation_display_id: conversation.display_id }, as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['message']).to eq('Suggested reply')
      end

      it 'returns the suggestion for a conversation_unassigned_manage role when the conversation is unassigned' do
        custom_role = create(:custom_role, account: account, permissions: ['conversation_unassigned_manage'])
        account.account_users.find_by(user_id: custom_agent.id).update!(custom_role: custom_role)
        allow_any_instance_of(Marine::Copilot::ReplySuggestionService).to receive(:perform).and_return(
          message: 'Suggested reply', error: nil
        )

        post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
             headers: custom_agent.create_new_auth_token,
             params: { conversation_display_id: conversation.display_id }, as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['message']).to eq('Suggested reply')
      end

      it 'returns forbidden for a conversation_unassigned_manage role when the conversation is assigned to another agent' do
        other_agent = create(:user, account: account, role: :agent)
        conversation.update!(assignee: other_agent)
        custom_role = create(:custom_role, account: account, permissions: ['conversation_unassigned_manage'])
        account.account_users.find_by(user_id: custom_agent.id).update!(custom_role: custom_role)
        spy_service(Marine::Copilot::ReplySuggestionService)

        post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
             headers: custom_agent.create_new_auth_token,
             params: { conversation_display_id: conversation.display_id }, as: :json

        expect(response).to have_http_status(:forbidden)
        expect(Marine::Copilot::ReplySuggestionService).not_to have_received(:new)
        expect(response.parsed_body).not_to have_key('message')
        expect(response.parsed_body).not_to have_key('follow_up_context')
      end

      it 'returns the suggestion for a conversation_participating_manage role when the custom agent participates' do
        create(:conversation_participant, conversation: conversation, account: account, user: custom_agent)
        custom_role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
        account.account_users.find_by(user_id: custom_agent.id).update!(custom_role: custom_role)
        allow_any_instance_of(Marine::Copilot::ReplySuggestionService).to receive(:perform).and_return(
          message: 'Suggested reply', error: nil
        )

        post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
             headers: custom_agent.create_new_auth_token,
             params: { conversation_display_id: conversation.display_id }, as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['message']).to eq('Suggested reply')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/tasks/summarize' do
    it 'returns not found without invoking the service when the display id is missing' do
      spy_service(Marine::Copilot::SummaryService)

      [nil, ''].each do |display_id|
        post "/api/v1/accounts/#{account.id}/marine/tasks/summarize",
             headers: agent.create_new_auth_token,
             params: { conversation_display_id: display_id }, as: :json

        expect(response).to have_http_status(:not_found)
      end

      expect(Marine::Copilot::SummaryService).not_to have_received(:new)
    end

    it 'returns not found for a cross-account display id' do
      spy_service(Marine::Copilot::SummaryService)

      post "/api/v1/accounts/#{account.id}/marine/tasks/summarize",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: other_conversations.last.display_id }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(Marine::Copilot::SummaryService).not_to have_received(:new)
    end

    it 'is unauthorized for an agent with neither inbox nor team access' do
      spy_service(Marine::Copilot::SummaryService)

      post "/api/v1/accounts/#{account.id}/marine/tasks/summarize",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(Marine::Copilot::SummaryService).not_to have_received(:new)
      expect(response.parsed_body).not_to have_key('message')
    end

    it 'returns the Marine-generated summary' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      allow_any_instance_of(Marine::Copilot::SummaryService).to receive(:perform).and_return(
        message: 'Conversation summary', error: nil, follow_up_context: { event_name: 'summarize' }
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/summarize",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Conversation summary')
      expect(response.parsed_body['follow_up_context']).to include('event_name' => 'summarize')
    end

    it 'returns the summary for an administrator' do
      allow_any_instance_of(Marine::Copilot::SummaryService).to receive(:perform).and_return(
        message: 'Conversation summary', error: nil
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/summarize",
           headers: administrator.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Conversation summary')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/tasks/translate' do
    it 'returns the translated content' do
      allow_any_instance_of(Marine::Copilot::TranslateService).to receive(:perform).and_return(
        message: 'Halo dunia', error: nil
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/translate",
           headers: agent.create_new_auth_token,
           params: { content: 'Hello world', target_language: 'id' }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Halo dunia')
    end

    it 'stays context-free and never resolves or authorizes a hidden conversation_display_id' do
      hidden_conversation = create(:conversation, account: account)
      service = instance_spy(Marine::Copilot::TranslateService, perform: { message: 'Halo dunia', error: nil })
      allow(Marine::Copilot::TranslateService).to receive(:new)
        .with(account: account, content: 'Hello world', target_language: 'id', source_language: nil).and_return(service)

      post "/api/v1/accounts/#{account.id}/marine/tasks/translate",
           headers: agent.create_new_auth_token,
           params: { content: 'Hello world', target_language: 'id', conversation_display_id: hidden_conversation.display_id },
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Halo dunia')
      expect(Marine::Copilot::TranslateService).to have_received(:new)
        .with(account: account, content: 'Hello world', target_language: 'id', source_language: nil)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/tasks/follow_up' do
    it 'returns not found without invoking the service when the display id is missing' do
      spy_service(Marine::Copilot::FollowUpService)

      post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: { follow_up_context: { event_name: 'improve' }, message: 'make it shorter' }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(Marine::Copilot::FollowUpService).not_to have_received(:new)
    end

    it 'is unauthorized for an agent with neither inbox nor team access' do
      spy_service(Marine::Copilot::FollowUpService)

      post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: { event_name: 'improve' },
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(Marine::Copilot::FollowUpService).not_to have_received(:new)
      expect(response.parsed_body).not_to have_key('message')
      expect(response.parsed_body).not_to have_key('follow_up_context')
    end

    it 'round-trips a server-issued token and preserves the payload shape' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      allow_any_instance_of(Marine::Copilot::ReplySuggestionService).to receive(:perform).and_return(
        message: 'Suggested reply', error: nil,
        follow_up_context: { event_name: 'reply_suggestion', original_context: 'customer transcript',
                             last_response: 'Suggested reply', conversation_history: [] }
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/reply_suggestion",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      stored = response.parsed_body['follow_up_context']
      expect(stored['token']).to be_a(String)

      allow_any_instance_of(Marine::Copilot::FollowUpService).to receive(:perform).and_return(
        message: 'Shorter reply', error: nil,
        follow_up_context: stored.except('token').merge('last_response' => 'Shorter reply')
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: stored,
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Shorter reply')
      expect(response.parsed_body['follow_up_context']).to include('event_name' => 'reply_suggestion')
      expect(response.parsed_body['follow_up_context']['token']).to be_a(String)
    end

    it 'rejects a conversation-bound token paired with a different accessible conversation' do
      other_conversation = create(:conversation, account: account)
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      create(:inbox_member, user: agent, inbox: other_conversation.inbox)
      stored = Wijaya::Batteries::CustomRoles::FollowUpProvenance.attach_token(
        { 'event_name' => 'reply_suggestion' }, account_id: account.id, conversation_display_id: conversation.display_id
      )
      spy_service(Marine::Copilot::FollowUpService)

      post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: stored,
             message: 'make it shorter',
             conversation_display_id: other_conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).not_to have_key('message')
      expect(response.parsed_body).not_to have_key('follow_up_context')
      expect(Marine::Copilot::FollowUpService).not_to have_received(:new)
    end

    it 'rejects a missing token (legacy unsigned context) fail-closed' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      spy_service(Marine::Copilot::FollowUpService)

      post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: { 'event_name' => 'improve', 'original_context' => 'x', 'last_response' => 'y' },
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Marine::Copilot::FollowUpService).not_to have_received(:new)
    end

    it 'rejects an invalid or tampered token fail-closed' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      spy_service(Marine::Copilot::FollowUpService)

      post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: { 'token' => 'tampered-token', 'event_name' => 'improve' },
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Marine::Copilot::FollowUpService).not_to have_received(:new)
    end

    it 'rejects a token issued for another account' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      spy_service(Marine::Copilot::FollowUpService)
      stored = Wijaya::Batteries::CustomRoles::FollowUpProvenance.attach_token(
        { 'event_name' => 'improve' },
        account_id: other_account.id, conversation_display_id: other_conversations.first.display_id
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: stored,
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Marine::Copilot::FollowUpService).not_to have_received(:new)
    end

    it 'rejects a tampered client context with an otherwise valid token fail-closed' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      canonical = { 'event_name' => 'improve', 'original_context' => 'raw draft',
                    'last_response' => 'Improved text', 'conversation_history' => [] }
      stored = Wijaya::Batteries::CustomRoles::FollowUpProvenance.attach_token(
        canonical, account_id: account.id, conversation_display_id: conversation.display_id
      )
      spy_service(Marine::Copilot::FollowUpService)

      post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: stored.merge('original_context' => 'EVIL', 'last_response' => 'EVIL'),
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Marine::Copilot::FollowUpService).not_to have_received(:new)
      expect(response.parsed_body).not_to have_key('message')
      expect(response.parsed_body).not_to have_key('follow_up_context')
    end

    it 'remains denied before the service when access was revoked after issuance' do
      member = create(:inbox_member, user: agent, inbox: conversation.inbox)
      stored = Wijaya::Batteries::CustomRoles::FollowUpProvenance.attach_token(
        { 'event_name' => 'improve' }, account_id: account.id, conversation_display_id: conversation.display_id
      )
      member.destroy!
      spy_service(Marine::Copilot::FollowUpService)

      post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: stored,
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(Marine::Copilot::FollowUpService).not_to have_received(:new)
    end

    it 'follows up a context-free rewrite token after independently authorizing the current conversation' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      allow_any_instance_of(Marine::Copilot::RewriteService).to receive(:perform).and_return(
        message: 'Improved text', error: nil,
        follow_up_context: { event_name: 'improve', original_context: 'raw',
                             last_response: 'Improved text', conversation_history: [] }
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/rewrite",
           headers: agent.create_new_auth_token,
           params: { content: 'raw', operation: 'improve' }, as: :json

      expect(response).to have_http_status(:success)
      stored = response.parsed_body['follow_up_context']
      expect(stored['token']).to be_a(String)

      allow_any_instance_of(Marine::Copilot::FollowUpService).to receive(:perform).and_return(
        message: 'Shorter reply', error: nil
      )

      post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: stored,
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Shorter reply')
    end

    it 'returns concise 422 for a malformed (non-object) follow_up_context' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      spy_service(Marine::Copilot::FollowUpService)

      ['just a string', %w[an array]].each do |malformed|
        post "/api/v1/accounts/#{account.id}/marine/tasks/follow_up",
             headers: agent.create_new_auth_token,
             params: {
               follow_up_context: malformed,
               message: 'make it shorter',
               conversation_display_id: conversation.display_id
             }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq('invalid_follow_up_context')
        expect(response.parsed_body).not_to have_key('message')
        expect(response.parsed_body).not_to have_key('follow_up_context')
      end

      expect(Marine::Copilot::FollowUpService).not_to have_received(:new)
    end
  end
end
