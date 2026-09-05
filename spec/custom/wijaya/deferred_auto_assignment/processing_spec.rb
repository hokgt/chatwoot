# frozen_string_literal: true

require 'rails_helper'

# Processing contract for the deferred auto-assignment battery: when an agent becomes
# available, InboxProcessor reruns the UNCHANGED native selector under a row lock for each
# marked conversation in that inbox, respecting team/capacity eligibility, never overwriting
# a claim present at the instant of its write, and cleaning up markers correctly.
RSpec.describe Wijaya::Batteries::DeferredAutoAssignment::InboxProcessor, type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  # Deterministic, Redis-free round-robin: pick the FIRST id from the online∩allowed set the
  # native AgentAssignmentService hands us. Proves the candidate SET, not Redis ordering.
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
    @online = []
    allow(OnlineStatusTracker).to receive(:get_available_users) { @online.index_with { 'online' } }
    allow(AutoAssignment::InboxRoundRobinService).to receive(:new).and_return(round_robin_picker)
    allow(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox)
  end

  def make_agent(inbox_member: true, team: nil)
    user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: user) if inbox_member
    create(:team_member, team: team, user: user) if team
    user
  end

  # Nobody online at creation -> the conversation is created open+unassigned and a deferred
  # marker is registered. Returns the marked, waiting conversation.
  def waiting_conversation(params = {})
    @online = []
    Conversation.create!({ account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox }.merge(params))
  end

  def marker_for(conversation)
    Wijaya::Batteries::DeferredAutoAssignment::Marker.find_by(conversation_id: conversation.id)
  end

  describe 'later availability assigns a waiting conversation' do
    it 'assigns the now-online agent and clears the marker' do
      agent = make_agent
      conversation = waiting_conversation
      expect(marker_for(conversation)).to be_present

      @online = [agent.id.to_s]
      described_class.process(inbox.id)

      expect(conversation.reload.assignee).to eq(agent)
      expect(marker_for(conversation)).to be_nil
    end

    it 'keeps the marker when no eligible agent is available yet' do
      make_agent
      conversation = waiting_conversation

      @online = [] # still nobody online
      described_class.process(inbox.id)

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_present
    end

    it 'keeps the marker active when an online agent has no assignment capacity' do
      agent = make_agent
      # Native capacity gate: the inbox caps assignments at 1 and the agent already owns an
      # open conversation, so member_ids_with_assignment_capacity excludes them. The agent is
      # online but has no capacity, so nobody can be assigned yet and the marker stays active.
      inbox.update!(auto_assignment_config: { 'max_assignment_limit' => 1 })
      create(:conversation, account: account, inbox: inbox, assignee: agent, status: :open)
      conversation = waiting_conversation

      @online = [agent.id.to_s]
      described_class.process(inbox.id)

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_present
    end
  end

  describe 'race protection: a claim present at write time is never overwritten' do
    it 'leaves a real SPV assignment untouched (marker already lifecycle-cleaned on the manual assign)' do
      agent = make_agent
      spv_agent = make_agent
      conversation = waiting_conversation
      expect(marker_for(conversation)).to be_present

      # SPV manually assigns and commits BEFORE processing runs. The battery concern's
      # after_update_commit lifecycle drops the now-stale marker immediately.
      conversation.update!(assignee: spv_agent)
      expect(marker_for(conversation)).to be_nil

      @online = [agent.id.to_s]
      described_class.process(inbox.id)

      expect(conversation.reload.assignee).to eq(spv_agent)
      expect(marker_for(conversation)).to be_nil
    end

    it 'row-locked recheck refuses to overwrite a claim that bypassed the lifecycle callback' do
      agent = make_agent
      spv_agent = make_agent
      conversation = waiting_conversation
      # Simulate a claim that reached the DB without firing the conversation callbacks, so the
      # marker survives to processing: only the row-locked recheck (deferrable?/assignable_now?)
      # protects it here.
      conversation.update_columns(assignee_id: spv_agent.id) # rubocop:disable Rails/SkipsModelValidations
      expect(marker_for(conversation)).to be_present

      @online = [agent.id.to_s]
      described_class.process(inbox.id)

      expect(conversation.reload.assignee).to eq(spv_agent)
      expect(marker_for(conversation)).to be_nil
    end

    it 'assigns when nobody has claimed yet, and a later manual assignment wins naturally' do
      agent = make_agent
      spv_agent = make_agent
      conversation = waiting_conversation

      # System write commits first while the row is still open + unclaimed.
      @online = [agent.id.to_s]
      described_class.process(inbox.id)
      expect(conversation.reload.assignee).to eq(agent)
      expect(marker_for(conversation)).to be_nil

      # A manual assignment that commits AFTER the system write wins by transaction ordering;
      # the battery makes no impossible claim of absolute priority over a later writer.
      conversation.update!(assignee: spv_agent)
      expect(conversation.reload.assignee).to eq(spv_agent)
    end
  end

  describe 'stored mapped team only selects a team member' do
    let(:team) { create(:team, account: account, allow_auto_assign: true) }

    it 'assigns the online inbox∩team member and excludes an online inbox-only member' do
      team_agent = make_agent(team: team)
      outside_agent = make_agent(team: nil) # inbox member, NOT a team member
      conversation = waiting_conversation(team: team)

      @online = [team_agent.id.to_s, outside_agent.id.to_s]
      described_class.process(inbox.id)

      expect(conversation.reload.assignee).to eq(team_agent)
      expect(conversation.assignee).not_to eq(outside_agent)
      expect(marker_for(conversation)).to be_nil
    end

    it 'assigns nobody and drops the marker when the team turns off auto-assign' do
      team_agent = make_agent(team: team)
      conversation = waiting_conversation(team: team)
      team.update!(allow_auto_assign: false)

      @online = [team_agent.id.to_s]
      described_class.process(inbox.id)

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_nil
    end
  end

  describe 'ineligible candidates are skipped and cleaned up at processing time' do
    it 'skips + cleans a conversation already owned by an agent bot' do
      agent = make_agent
      agent_bot = create(:agent_bot, account: account)
      conversation = waiting_conversation
      conversation.update_columns(assignee_agent_bot_id: agent_bot.id) # rubocop:disable Rails/SkipsModelValidations

      @online = [agent.id.to_s]
      described_class.process(inbox.id)

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_nil
    end

    it 'skips + cleans a non-open (resolved) conversation whose marker outlived the callback' do
      agent = make_agent
      conversation = waiting_conversation
      # update_columns bypasses the lifecycle callback so the marker survives to processing,
      # exercising the row-locked deferrable? recheck rather than the concern cleanup.
      conversation.update_columns(status: Conversation.statuses[:resolved]) # rubocop:disable Rails/SkipsModelValidations
      expect(marker_for(conversation)).to be_present

      @online = [agent.id.to_s]
      described_class.process(inbox.id)

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_nil
    end
  end

  describe 'unmarked historical conversations are never touched' do
    it 'ignores an open unassigned conversation that has no marker' do
      agent = make_agent
      historical = waiting_conversation
      # Simulate a pre-feature row: it exists open+unassigned but carries no marker.
      Wijaya::Batteries::DeferredAutoAssignment::Marker.where(conversation_id: historical.id).delete_all

      @online = [agent.id.to_s]
      described_class.process(inbox.id)

      expect(historical.reload.assignee_id).to be_nil
    end
  end
end
