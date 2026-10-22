# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/custom_roles/follow_up_provenance')

RSpec.describe 'Captain Tasks API', type: :request do
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

  def stub_result(service_class, result)
    service = instance_spy(service_class, perform: result)
    allow(service_class).to receive(:new).and_return(service)
    service
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/tasks/summarize' do
    it 'returns unauthorized for an unauthenticated user' do
      post "/api/v1/accounts/#{account.id}/captain/tasks/summarize",
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns not found without instantiating the service when the display id is missing' do
      spy_service(Captain::SummaryService)

      [nil, ''].each do |display_id|
        post "/api/v1/accounts/#{account.id}/captain/tasks/summarize",
             headers: administrator.create_new_auth_token,
             params: { conversation_display_id: display_id }, as: :json

        expect(response).to have_http_status(:not_found)
      end

      expect(Captain::SummaryService).not_to have_received(:new)
      expect(response.parsed_body).not_to have_key('message')
    end

    it 'returns not found for a cross-account display id' do
      spy_service(Captain::SummaryService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/summarize",
           headers: administrator.create_new_auth_token,
           params: { conversation_display_id: other_conversations.last.display_id }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(Captain::SummaryService).not_to have_received(:new)
    end

    it 'is unauthorized for an agent with neither inbox nor team access' do
      spy_service(Captain::SummaryService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/summarize",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(Captain::SummaryService).not_to have_received(:new)
      expect(response.parsed_body).not_to have_key('message')
      expect(response.parsed_body).not_to have_key('follow_up_context')
    end

    it 'summarizes for an administrator' do
      stub_result(Captain::SummaryService, { message: 'Summary', error: nil })

      post "/api/v1/accounts/#{account.id}/captain/tasks/summarize",
           headers: administrator.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Summary')
    end

    it 'summarizes for an agent with inbox access' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      stub_result(Captain::SummaryService, { message: 'Summary', error: nil })

      post "/api/v1/accounts/#{account.id}/captain/tasks/summarize",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Summary')
    end

    it 'summarizes for an agent with team access' do
      team = create(:team, account: account)
      conversation.update!(team: team)
      create(:team_member, team: team, user: agent)
      stub_result(Captain::SummaryService, { message: 'Summary', error: nil })

      post "/api/v1/accounts/#{account.id}/captain/tasks/summarize",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Summary')
    end

    describe 'custom roles', :enterprise do
      let(:custom_agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, user: custom_agent, inbox: conversation.inbox)
      end

      it 'returns forbidden for a restrictive role without invoking the service' do
        custom_role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
        account.account_users.find_by(user_id: custom_agent.id).update!(custom_role: custom_role)
        spy_service(Captain::SummaryService)

        post "/api/v1/accounts/#{account.id}/captain/tasks/summarize",
             headers: custom_agent.create_new_auth_token,
             params: { conversation_display_id: conversation.display_id }, as: :json

        expect(response).to have_http_status(:forbidden)
        expect(Captain::SummaryService).not_to have_received(:new)
        expect(response.parsed_body).not_to have_key('message')
        expect(response.parsed_body).not_to have_key('follow_up_context')
      end

      it 'summarizes for a conversation_manage role on an accessible inbox conversation' do
        custom_role = create(:custom_role, account: account, permissions: ['conversation_manage'])
        account.account_users.find_by(user_id: custom_agent.id).update!(custom_role: custom_role)
        stub_result(Captain::SummaryService, { message: 'Summary', error: nil })

        post "/api/v1/accounts/#{account.id}/captain/tasks/summarize",
             headers: custom_agent.create_new_auth_token,
             params: { conversation_display_id: conversation.display_id }, as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['message']).to eq('Summary')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/tasks/reply_suggestion' do
    it 'returns not found without instantiating the service when the display id is missing' do
      spy_service(Captain::ReplySuggestionService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/reply_suggestion",
           headers: administrator.create_new_auth_token,
           params: { conversation_display_id: '' }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(Captain::ReplySuggestionService).not_to have_received(:new)
    end

    it 'is unauthorized for an agent with neither inbox nor team access' do
      spy_service(Captain::ReplySuggestionService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/reply_suggestion",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(Captain::ReplySuggestionService).not_to have_received(:new)
    end

    it 'suggests a reply for an agent with inbox access' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      stub_result(Captain::ReplySuggestionService, { message: 'Suggested reply', error: nil })

      post "/api/v1/accounts/#{account.id}/captain/tasks/reply_suggestion",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Suggested reply')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/tasks/label_suggestion' do
    it 'returns not found without instantiating the service when the display id is missing' do
      spy_service(Captain::LabelSuggestionService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/label_suggestion",
           headers: administrator.create_new_auth_token,
           params: { conversation_display_id: '' }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(Captain::LabelSuggestionService).not_to have_received(:new)
    end

    it 'is unauthorized for an agent with neither inbox nor team access' do
      spy_service(Captain::LabelSuggestionService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/label_suggestion",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(Captain::LabelSuggestionService).not_to have_received(:new)
    end

    it 'suggests labels for an agent with inbox access' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      stub_result(Captain::LabelSuggestionService, { message: 'billing', error: nil })

      post "/api/v1/accounts/#{account.id}/captain/tasks/label_suggestion",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('billing')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/tasks/follow_up' do
    it 'returns not found without instantiating the service when the display id is missing' do
      spy_service(Captain::FollowUpService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: { follow_up_context: { event_name: 'improve' }, message: 'make it shorter' }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(Captain::FollowUpService).not_to have_received(:new)
    end

    it 'is unauthorized for an agent with neither inbox nor team access' do
      spy_service(Captain::FollowUpService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: { event_name: 'improve' },
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(Captain::FollowUpService).not_to have_received(:new)
      expect(response.parsed_body).not_to have_key('message')
      expect(response.parsed_body).not_to have_key('follow_up_context')
    end

    it 'round-trips a server-issued token and preserves the payload shape' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      stub_result(Captain::ReplySuggestionService,
                  { message: 'Suggested reply', error: nil,
                    follow_up_context: { 'event_name' => 'reply_suggestion', 'original_context' => 'customer transcript',
                                         'last_response' => 'Suggested reply', 'conversation_history' => [] } })

      post "/api/v1/accounts/#{account.id}/captain/tasks/reply_suggestion",
           headers: agent.create_new_auth_token,
           params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      stored = response.parsed_body['follow_up_context']
      expect(stored['token']).to be_a(String)

      stub_result(Captain::FollowUpService,
                  { message: 'Shorter reply', error: nil,
                    follow_up_context: stored.except('token').merge('last_response' => 'Shorter reply') })

      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
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
      spy_service(Captain::FollowUpService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: stored,
             message: 'make it shorter',
             conversation_display_id: other_conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).not_to have_key('message')
      expect(response.parsed_body).not_to have_key('follow_up_context')
      expect(Captain::FollowUpService).not_to have_received(:new)
    end

    it 'rejects a missing token (legacy unsigned context) fail-closed' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      spy_service(Captain::FollowUpService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: { 'event_name' => 'improve', 'original_context' => 'x', 'last_response' => 'y' },
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Captain::FollowUpService).not_to have_received(:new)
    end

    it 'rejects an invalid or tampered token fail-closed' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      spy_service(Captain::FollowUpService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: { 'token' => 'tampered-token', 'event_name' => 'improve' },
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Captain::FollowUpService).not_to have_received(:new)
    end

    it 'rejects a token issued for another account' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      spy_service(Captain::FollowUpService)
      stored = Wijaya::Batteries::CustomRoles::FollowUpProvenance.attach_token(
        { 'event_name' => 'improve' },
        account_id: other_account.id, conversation_display_id: other_conversations.first.display_id
      )

      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: stored,
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Captain::FollowUpService).not_to have_received(:new)
    end

    it 'rejects a tampered client context with an otherwise valid token fail-closed' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      canonical = { 'event_name' => 'improve', 'original_context' => 'raw draft',
                    'last_response' => 'Improved text', 'conversation_history' => [] }
      stored = Wijaya::Batteries::CustomRoles::FollowUpProvenance.attach_token(
        canonical, account_id: account.id, conversation_display_id: conversation.display_id
      )
      spy_service(Captain::FollowUpService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: stored.merge('original_context' => 'EVIL', 'last_response' => 'EVIL'),
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Captain::FollowUpService).not_to have_received(:new)
      expect(response.parsed_body).not_to have_key('message')
      expect(response.parsed_body).not_to have_key('follow_up_context')
    end

    it 'remains denied before the service when access was revoked after issuance' do
      member = create(:inbox_member, user: agent, inbox: conversation.inbox)
      stored = Wijaya::Batteries::CustomRoles::FollowUpProvenance.attach_token(
        { 'event_name' => 'improve' }, account_id: account.id, conversation_display_id: conversation.display_id
      )
      member.destroy!
      spy_service(Captain::FollowUpService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: stored,
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(Captain::FollowUpService).not_to have_received(:new)
    end

    it 'follows up a context-free rewrite token after independently authorizing the current conversation' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      stub_result(Captain::RewriteService,
                  { message: 'Better', error: nil,
                    follow_up_context: { 'event_name' => 'improve', 'original_context' => 'raw',
                                         'last_response' => 'Better', 'conversation_history' => [] } })

      post "/api/v1/accounts/#{account.id}/captain/tasks/rewrite",
           headers: agent.create_new_auth_token,
           params: { content: 'raw', operation: 'improve' }, as: :json

      expect(response).to have_http_status(:success)
      stored = response.parsed_body['follow_up_context']
      expect(stored['token']).to be_a(String)

      stub_result(Captain::FollowUpService, { message: 'Shorter reply', error: nil })

      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: {
             follow_up_context: stored,
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Shorter reply')
    end

    it 'returns forbidden for a restrictive custom role without invoking the service', :enterprise do
      custom_agent = create(:user, account: account, role: :agent)
      create(:inbox_member, user: custom_agent, inbox: conversation.inbox)
      custom_role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
      account.account_users.find_by(user_id: custom_agent.id).update!(custom_role: custom_role)
      spy_service(Captain::FollowUpService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
           headers: custom_agent.create_new_auth_token,
           params: {
             follow_up_context: { event_name: 'improve' },
             message: 'make it shorter',
             conversation_display_id: conversation.display_id
           }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Captain::FollowUpService).not_to have_received(:new)
    end

    it 'returns concise 422 for a malformed (non-object) follow_up_context' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      spy_service(Captain::FollowUpService)

      ['just a string', %w[an array]].each do |malformed|
        post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
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

      expect(Captain::FollowUpService).not_to have_received(:new)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/tasks/rewrite' do
    it 'works without a conversation and passes a nil conversation display id' do
      service = instance_spy(Captain::RewriteService, perform: { message: 'Better', error: nil })
      allow(Captain::RewriteService).to receive(:new)
        .with(account: account, content: 'raw', operation: 'improve', conversation_display_id: nil).and_return(service)

      post "/api/v1/accounts/#{account.id}/captain/tasks/rewrite",
           headers: agent.create_new_auth_token,
           params: { content: 'raw', operation: 'improve' }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Better')
      expect(Captain::RewriteService).to have_received(:new)
        .with(account: account, content: 'raw', operation: 'improve', conversation_display_id: nil)
    end

    it 'authorizes a supplied conversation display id before invoking the service' do
      spy_service(Captain::RewriteService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/rewrite",
           headers: agent.create_new_auth_token,
           params: { content: 'raw', operation: 'improve', conversation_display_id: conversation.display_id },
           as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(Captain::RewriteService).not_to have_received(:new)
    end

    it 'returns not found for a supplied cross-account display id' do
      spy_service(Captain::RewriteService)

      post "/api/v1/accounts/#{account.id}/captain/tasks/rewrite",
           headers: agent.create_new_auth_token,
           params: { content: 'raw', operation: 'improve', conversation_display_id: other_conversations.last.display_id },
           as: :json

      expect(response).to have_http_status(:not_found)
      expect(Captain::RewriteService).not_to have_received(:new)
    end

    it 'rewrites with a supplied id when the agent has inbox access' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      stub_result(Captain::RewriteService, { message: 'Better', error: nil })

      post "/api/v1/accounts/#{account.id}/captain/tasks/rewrite",
           headers: agent.create_new_auth_token,
           params: { content: 'raw', operation: 'improve', conversation_display_id: conversation.display_id },
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Better')
    end

    it 'binds token issuance to the authorized canonical display id, not raw params' do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      stub_result(Captain::RewriteService,
                  { message: 'Better', error: nil,
                    follow_up_context: { 'event_name' => 'improve', 'original_context' => 'raw',
                                         'last_response' => 'Better', 'conversation_history' => [] } })

      zero_padded = format('%03d', conversation.display_id)
      post "/api/v1/accounts/#{account.id}/captain/tasks/rewrite",
           headers: agent.create_new_auth_token,
           params: { content: 'raw', operation: 'improve', conversation_display_id: zero_padded }, as: :json

      expect(response).to have_http_status(:success)
      stored = response.parsed_body['follow_up_context']

      verifier = Rails.application.message_verifier(Wijaya::Batteries::CustomRoles::FollowUpProvenance::VERIFIER_NAME)
      expect(verifier.verified(stored['token'],
                               purpose: "v1/account-#{account.id}/conversation-#{conversation.display_id}")).to be_present
      expect(verifier.verified(stored['token'],
                               purpose: "v1/account-#{account.id}/conversation-#{zero_padded}")).to be_nil

      stub_result(Captain::FollowUpService, { message: 'Shorter reply', error: nil })
      post "/api/v1/accounts/#{account.id}/captain/tasks/follow_up",
           headers: agent.create_new_auth_token,
           params: { follow_up_context: stored, message: 'make it shorter',
                     conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['message']).to eq('Shorter reply')
    end
  end
end
