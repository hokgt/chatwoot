require 'rails_helper'

RSpec.describe 'Conversation Assignment API', type: :request do
  let(:account) { create(:account) }

  describe 'POST /api/v1/accounts/{account.id}/conversations/<id>/assignments' do
    let(:conversation) { create(:conversation, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post api_v1_account_conversation_assignments_url(account_id: account.id, conversation_id: conversation.display_id)

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated bot with out access to the inbox' do
      let(:agent_bot) { create(:agent_bot) }
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: conversation.inbox, user: agent)
      end

      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/assignments",
             headers: { api_access_token: agent_bot.access_token.token },
             params: {
               assignee_id: agent.id
             },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user with access to the inbox' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:supervisor_role) { create(:custom_role, account: account, permissions: ['conversation_manage']) }
      let(:agent_bot) { create(:agent_bot, account: account) }
      let(:team) { create(:team, account: account) }

      before do
        agent.current_account_user.update!(custom_role: supervisor_role)
        create(:inbox_member, inbox: conversation.inbox, user: agent)
      end

      it 'assigns a user to the conversation' do
        params = { assignee_id: agent.id }

        post api_v1_account_conversation_assignments_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.assignee).to eq(agent)
      end

      it 'assigns an agent bot to the conversation' do
        params = { assignee_id: agent_bot.id, assignee_type: 'AgentBot' }

        expect(Conversations::AssignmentService).to receive(:new)
          .with(hash_including(conversation: conversation, assignee_id: agent_bot.id, assignee_type: 'AgentBot'))
          .and_call_original

        post api_v1_account_conversation_assignments_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['name']).to eq(agent_bot.name)
        conversation.reload
        expect(conversation.assignee_agent_bot).to eq(agent_bot)
        expect(conversation.assignee).to be_nil
      end

      it 'assigns a team to the conversation' do
        team_member = create(:user, account: account, role: :agent, auto_offline: false)
        create(:inbox_member, inbox: conversation.inbox, user: team_member)
        create(:team_member, team: team, user: team_member)
        params = { team_id: team.id }

        post api_v1_account_conversation_assignments_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.team).to eq(team)
        # assignee will be from team
        expect(conversation.reload.assignee).to eq(team_member)
      end
    end


    context 'with custom role assignment permissions' do
      let(:assignee) { create(:user, account: account, role: :agent) }
      let(:sales_role) { create(:custom_role, account: account, name: 'Sales', permissions: ['conversation_participating_manage']) }
      let(:marketing_role) { create(:custom_role, account: account, name: 'Marketing', permissions: ['conversation_participating_manage']) }
      let(:supervisor_role) { create(:custom_role, account: account, name: 'Supervisor', permissions: ['conversation_manage']) }
      let(:sales_agent) { create(:user, account: account, role: :agent) }
      let(:marketing_agent) { create(:user, account: account, role: :agent) }
      let(:supervisor) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      before do
        [assignee, sales_agent, marketing_agent, supervisor, administrator].each do |user|
          create(:inbox_member, inbox: conversation.inbox, user: user)
        end
        sales_agent.current_account_user.update!(custom_role: sales_role)
        marketing_agent.current_account_user.update!(custom_role: marketing_role)
        supervisor.current_account_user.update!(custom_role: supervisor_role)
        administrator.current_account_user.update!(custom_role: sales_role)
      end

      it 'returns 403 for Sales when assigning via direct API' do
        post api_v1_account_conversation_assignments_url(account_id: account.id, conversation_id: conversation.display_id),
             params: { assignee_id: assignee.id },
             headers: sales_agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:forbidden)
        expect(conversation.reload.assignee).to be_nil
      end

      it 'returns 403 for Marketing when assigning via direct API' do
        post api_v1_account_conversation_assignments_url(account_id: account.id, conversation_id: conversation.display_id),
             params: { assignee_id: assignee.id },
             headers: marketing_agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:forbidden)
        expect(conversation.reload.assignee).to be_nil
      end

      it 'allows Supervisor to assign via direct API' do
        post api_v1_account_conversation_assignments_url(account_id: account.id, conversation_id: conversation.display_id),
             params: { assignee_id: assignee.id },
             headers: supervisor.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.assignee).to eq(assignee)
      end

      it 'allows Administrator to assign via direct API' do
        post api_v1_account_conversation_assignments_url(account_id: account.id, conversation_id: conversation.display_id),
             params: { assignee_id: assignee.id },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.assignee).to eq(assignee)
      end
    end

    context 'when it is an authenticated bot with access to the inbox' do
      let(:agent_bot) { create(:agent_bot, account: account) }
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:team) { create(:team, account: account) }

      before do
        create(:agent_bot_inbox, inbox: conversation.inbox, agent_bot: agent_bot)
      end

      it 'assignment of an agent in the conversation by bot agent' do
        create(:inbox_member, user: agent, inbox: conversation.inbox)

        conversation.update!(assignee_id: nil)
        expect(conversation.reload.assignee).to be_nil

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/assignments",
             headers: { api_access_token: agent_bot.access_token.token },
             params: {
               assignee_id: agent.id
             },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.assignee).to eq(agent)
      end

      it 'assignment of an team in the conversation by bot agent' do
        create(:inbox_member, user: agent, inbox: conversation.inbox)

        conversation.update!(team_id: nil)
        expect(conversation.reload.team).to be_nil

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/assignments",
             headers: { api_access_token: agent_bot.access_token.token },
             params: {
               team_id: team.id
             },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.team).to eq(team)
      end
    end

    context 'when conversation already has an assignee' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:supervisor_role) { create(:custom_role, account: account, permissions: ['conversation_manage']) }

      before do
        agent.current_account_user.update!(custom_role: supervisor_role)
        create(:inbox_member, inbox: conversation.inbox, user: agent)
        conversation.update!(assignee: agent)
      end

      it 'unassigns the assignee from the conversation' do
        params = { assignee_id: nil }
        post api_v1_account_conversation_assignments_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.assignee).to be_nil
        expect(Conversations::ActivityMessageJob)
          .to(have_been_enqueued.at_least(:once)
        .with(conversation, { account_id: conversation.account_id, inbox_id: conversation.inbox_id, message_type: :activity,
                              content: "Conversation unassigned by #{agent.name}" }))
      end
    end

    context 'when conversation already has a team' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:team) { create(:team, account: account) }
      let(:supervisor_role) { create(:custom_role, account: account, permissions: ['conversation_manage']) }

      before do
        agent.current_account_user.update!(custom_role: supervisor_role)
        conversation.update!(team: team)
        create(:inbox_member, inbox: conversation.inbox, user: agent)
      end

      it 'unassigns the team from the conversation' do
        params = { team_id: 0 }
        post api_v1_account_conversation_assignments_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.team).to be_nil
      end
    end
  end
end
