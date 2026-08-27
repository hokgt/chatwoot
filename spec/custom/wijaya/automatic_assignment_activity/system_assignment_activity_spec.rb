# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/meta_ads_team_routing/routing_service')
require Rails.root.join('custom/wijaya/batteries/meta_ads_team_routing/routing_rule')
require Rails.root.join('custom/wijaya/batteries/automatic_assignment_activity/system_assignment')

# Acceptance for the automatic-assignment activity battery: native auto-assignment must
# persist exactly one "Assigned to <Agent> by the System" timeline activity, while manual
# assignment keeps its human actor and a no-eligible-agent routing leaves no false badge.
#
# The activity content is read off the enqueued Conversations::ActivityMessageJob rather
# than executed, so no example performs the message create (which would fetch contact
# avatars over the network under WebMock). Redis-touching boundaries are stubbed exactly
# as in the Meta Ads acceptance spec (OnlineStatusTracker presence map, the round-robin
# selector, the V2 AssignmentJob.enqueue_for_inbox coalescing key). Everything else —
# AssignmentHandler (Path A, before_save team routing), AutoAssignmentHandler (Path B,
# after_save legacy inbox round-robin), and the native activity handlers — runs as real
# production code.
RSpec.describe 'Automatic assignment activity (acceptance)', type: :model do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:team) { create(:team, account: account, allow_auto_assign: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:source_id) { 'AD_SYS_1' }
  let!(:rule) do
    Wijaya::MetaAdsTeamRoutingRule.create!(account: account, team: team, source_id: source_id, status: :active)
  end

  let(:online_ids) { [] }
  let(:round_robin_picker) do
    instance_double(AutoAssignment::InboxRoundRobinService).tap do |picker|
      allow(picker).to receive(:add_agent_to_queue)
      allow(picker).to receive(:remove_agent_from_queue)
      allow(picker).to receive(:clear_queue)
      allow(picker).to receive(:reset_queue)
      allow(picker).to receive(:available_agent) do |allowed_agent_ids:|
        ids = Array(allowed_agent_ids)
        ids.empty? ? nil : User.find_by(id: ids.first)
      end
    end
  end

  before do
    allow(AutoAssignment::InboxRoundRobinService).to receive(:new).and_return(round_robin_picker)
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return(online_ids.index_with { 'online' })
    allow(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox)
  end

  # Content of every enqueued activity-message create for the run.
  def assignment_activities
    enqueued_jobs
      .select { |job| job[:job] == Conversations::ActivityMessageJob }
      .map { |job| job[:args][1]['content'] || job[:args][1][:content] }
  end

  def make_agent(team_member: true, inbox_member: true)
    user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: user) if inbox_member
    create(:team_member, team: team, user: user) if team_member
    user
  end

  def create_routed_conversation
    routed = Wijaya::Batteries::MetaAdsTeamRouting::RoutingService.apply!(
      account: account, inbox: inbox, channel: :whatsapp,
      referral: { source_id: source_id, source_type: 'ad' },
      conversation_params: { account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox }
    )
    Conversation.create!(routed)
  end

  describe 'native team routing at create (Path A, before_save)' do
    let!(:agent) { make_agent }
    let(:online_ids) { [agent.id.to_s] }

    it 'records exactly one "Assigned to <Agent> by the System" activity and no team badge' do
      conversation = create_routed_conversation

      expect(conversation.assignee).to eq(agent)
      expect(assignment_activities).to contain_exactly("Assigned to #{agent.name} by the System")
    end
  end

  describe 'native legacy inbox round-robin (Path B, after_save, no team)' do
    let!(:agent) { create(:user, account: account, role: :agent) }
    let(:online_ids) { [agent.id.to_s] }

    before { create(:inbox_member, inbox: inbox, user: agent) }

    it 'records "Assigned to <Agent> by the System"' do
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact,
                                           contact_inbox: contact_inbox, assignee: nil)

      expect(conversation.reload.assignee).to eq(agent)
      expect(assignment_activities).to contain_exactly("Assigned to #{agent.name} by the System")
    end
  end

  describe 'team routing with no eligible agent' do
    let!(:agent) { make_agent } # eligible member exists but is offline
    let(:online_ids) { [] }

    it 'leaves assignee nil and records no assignment activity' do
      conversation = create_routed_conversation

      expect(conversation.team).to eq(team)
      expect(conversation.assignee).to be_nil
      expect(assignment_activities).to be_empty
    end
  end

  describe 'manual assignment by a human' do
    let!(:agent) { create(:user, account: account, role: :agent) }
    let(:actor) { create(:user, account: account, role: :administrator) }

    before { create(:inbox_member, inbox: inbox, user: agent) }

    it 'keeps the human actor and never says System' do
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact,
                                           contact_inbox: contact_inbox, assignee: nil)
      Current.user = actor
      conversation.update!(assignee: agent)
      Current.user = nil

      expect(assignment_activities).to contain_exactly("Assigned to #{agent.name} by #{actor.name}")
      expect(assignment_activities).not_to include(a_string_including('by the System'))
    end
  end

  describe 'Wijaya::Batteries::AutomaticAssignmentActivity::SystemAssignment guards' do
    subject(:system_assignment) { Wijaya::Batteries::AutomaticAssignmentActivity::SystemAssignment }

    let(:conversation) { instance_double(Conversation) }

    it 'returns nil when the conversation was never marked' do
      allow(conversation).to receive(:instance_variable_defined?).and_return(false)
      expect(system_assignment.actor_for(conversation, nil)).to be_nil
    end

    context 'when marked and the assignee changed to a present agent' do
      before do
        system_assignment.mark(conversation)
        allow(conversation).to receive_messages(saved_change_to_assignee_id?: true, assignee_id: 42)
      end

      it 'returns "the System" for an actor-less native auto-assignment' do
        expect(system_assignment.actor_for(conversation, nil)).to eq('the System')
      end

      it 'defers to the human actor when a Current.user name is present' do
        expect(system_assignment.actor_for(conversation, 'Jane Agent')).to be_nil
      end

      it 'defers to a more specific automation actor when Current.executed_by is set' do
        Current.executed_by = Object.new
        expect(system_assignment.actor_for(conversation, nil)).to be_nil
      ensure
        Current.executed_by = nil
      end

      it 'consumes the mark so a later change on the same instance is not relabeled' do
        expect(system_assignment.actor_for(conversation, nil)).to eq('the System')
        expect(system_assignment.actor_for(conversation, nil)).to be_nil
      end
    end
  end
end
