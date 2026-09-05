# frozen_string_literal: true

require 'rails_helper'

# Registration contract for the deferred auto-assignment battery: a brand-new conversation
# gets a durable marker at after_create_commit ONLY when native legacy creation-time
# auto-assignment was applicable but found no eligible ONLINE agent. Immediate assignment
# is unchanged; V2 and non-applicable inboxes are never marked; manual unassignment later
# never re-registers.
RSpec.describe 'Deferred auto-assignment registration', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  # Presence map { user_id_string => 'online' }; examples override online_ids.
  let(:online_ids) { [] }

  # Deterministic, Redis-free round-robin over the online∩allowed set the native
  # AgentAssignmentService computes (same pattern as the Meta Ads acceptance spec).
  let(:round_robin_picker) do
    instance_double(AutoAssignment::InboxRoundRobinService).tap do |picker|
      %i[add_agent_to_queue remove_agent_from_queue clear_queue reset_queue].each { |m| allow(picker).to receive(m) }
      allow(picker).to receive(:available_agent) do |allowed_agent_ids:|
        ids = Array(allowed_agent_ids)
        ids.empty? ? nil : User.find_by(id: ids.first)
      end
    end
  end

  before do
    allow(AutoAssignment::InboxRoundRobinService).to receive(:new).and_return(round_robin_picker)
    allow(OnlineStatusTracker).to receive(:get_available_users) { online_ids.index_with { 'online' } }
    # Guard the V2 after_save branch from touching live Redis if an example enables V2.
    allow(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox)
  end

  def marker_for(conversation)
    Wijaya::Batteries::DeferredAutoAssignment::Marker.find_by(conversation_id: conversation.id)
  end

  def make_agent(inbox_member: true, team: nil)
    user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: user) if inbox_member
    create(:team_member, team: team, user: user) if team
    user
  end

  def create_conversation(params = {})
    Conversation.create!({ account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox }.merge(params))
  end

  context 'when an eligible agent is online at creation (immediate assignment unchanged)' do
    let!(:agent) { make_agent }
    let(:online_ids) { [agent.id.to_s] }

    it 'assigns immediately and leaves no deferred marker' do
      conversation = create_conversation

      expect(conversation.assignee).to eq(agent)
      expect(marker_for(conversation)).to be_nil
    end
  end

  context 'when no eligible agent is online at creation' do
    let!(:agent) { make_agent }
    let(:online_ids) { [] }

    it 'stays open + human/bot-unassigned and records a deferred marker' do
      conversation = create_conversation

      expect(conversation).to be_open
      expect(conversation.assignee_id).to be_nil
      expect(conversation.assignee_agent_bot_id).to be_nil
      marker = marker_for(conversation)
      expect(marker).to be_present
      expect(marker.inbox_id).to eq(inbox.id)
      expect(marker.account_id).to eq(account.id)
      # Naturally visible in the Unassigned/All server-side scopes (no new status).
      expect(Conversation.where(assignee_id: nil)).to include(conversation)
      expect(inbox.conversations.where(status: :open, assignee_id: nil)).to include(conversation)
    end
  end

  context 'with a team conversation (Meta Ads-style routing)' do
    let(:team) { create(:team, account: account, allow_auto_assign: true) }
    let!(:agent) { make_agent(team: team) }
    let(:online_ids) { [] }

    it 'records a marker when the team allows auto-assign but nobody is online' do
      conversation = create_conversation(team: team)

      expect(conversation.team).to eq(team)
      expect(conversation.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_present
    end

    it 'records no marker when team.allow_auto_assign is false' do
      team.update!(allow_auto_assign: false)

      conversation = create_conversation(team: team)

      expect(conversation.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_nil
    end
  end

  context 'when inbox auto-assignment is not applicable' do
    let!(:agent) { make_agent }
    let(:online_ids) { [] }

    it 'records no marker when the inbox has auto-assignment disabled (non-team)' do
      inbox.update!(enable_auto_assignment: false)

      conversation = create_conversation

      expect(marker_for(conversation)).to be_nil
    end

    it 'records no marker when the inbox is on Assignment V2' do
      allow_any_instance_of(Inbox).to receive(:auto_assignment_v2_enabled?).and_return(true)

      conversation = create_conversation

      expect(marker_for(conversation)).to be_nil
    end
  end

  context 'when an agent bot owns the new conversation' do
    let(:agent_bot) { create(:agent_bot, account: account) }
    let(:online_ids) { [] }

    it 'records no marker (bot handles it)' do
      conversation = create_conversation(assignee_agent_bot_id: agent_bot.id)

      expect(marker_for(conversation)).to be_nil
    end
  end

  context 'when a marked conversation is later manually unassigned' do
    let!(:agent) { make_agent }
    let(:online_ids) { [agent.id.to_s] }

    it 'does not re-register a marker (registration is creation-only)' do
      conversation = create_conversation
      expect(conversation.assignee).to eq(agent)

      conversation.update!(assignee_id: nil)

      expect(marker_for(conversation)).to be_nil
    end
  end
end
