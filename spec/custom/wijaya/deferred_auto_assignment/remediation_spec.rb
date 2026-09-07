# frozen_string_literal: true

require 'rails_helper'

# Focused regression coverage for the deferred auto-assignment remediation. Each block pins a
# specific blocker so a future change that reintroduces the hazard fails here:
#
#   #1  empty online presence yields a safe nil from the UNCHANGED native selector, never a
#       crash (nil ∩ allowed ids), and processing keeps the marker.
#   #2a registrar enqueues a coalesced pass right after writing the marker, closing the
#       trigger-before-marker race.
#   #2b in-flight rerun handshake: a coalesced trigger records a rerun request; the running job
#       releases its claim then consumes the request and enqueues exactly one more pass (no lost
#       wakeup); with no request pending it never re-enqueues (no storm).
#   #3a freed assignment capacity (a conversation resolved / reassigned) enqueues a marker-gated
#       recovery pass; a first assignment (no prior assignee) does not.
#   #3b a new inbox member enqueues a marker-gated pass only when the inbox holds a marker.
#   #3c a new team member enqueues only for inboxes holding a marker routed to that team.
#   #6  a parent-row deletion that bypasses the has_one dependent callback still removes the
#       marker via the FK on_delete: :cascade.
RSpec.describe 'Deferred auto-assignment remediation', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  let(:trigger_service) { Wijaya::Batteries::DeferredAutoAssignment::TriggerService }
  let(:process_job) { Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob }
  let(:processor) { Wijaya::Batteries::DeferredAutoAssignment::InboxProcessor }

  before do
    @online = {}
    allow(OnlineStatusTracker).to receive(:get_available_users) { @online }
    allow(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox)
  end

  def make_agent(inbox_member: true, team: nil)
    user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: user) if inbox_member
    create(:team_member, team: team, user: user) if team
    user
  end

  # Nobody online at creation -> the conversation is created open+unassigned and marked.
  def waiting_conversation(params = {})
    @online = {}
    Conversation.create!({ account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox }.merge(params))
  end

  def marker_for(conversation)
    Wijaya::Batteries::DeferredAutoAssignment::Marker.find_by(conversation_id: conversation.id)
  end

  describe 'blocker #1: empty online presence is a safe nil, never a crash' do
    it 'returns nil from the real native selector when nobody is online (nil intersection)' do
      agent = make_agent
      conversation = waiting_conversation
      @online = {} # OnlineStatusTracker.get_available_users -> {} => online_agent_ids is nil

      # Deliberately NOT stubbing InboxRoundRobinService: this exercises the real
      # nil-intersection path (nil & allowed_ids => false => available_agent short-circuits).
      service = AutoAssignment::AgentAssignmentService.new(
        conversation: conversation, allowed_agent_ids: [agent.id]
      )

      assignee = :unset
      expect { assignee = service.find_assignee }.not_to raise_error
      expect(assignee).to be_nil
    end

    it 'keeps the marker (no assignment) when processing finds nobody online' do
      make_agent
      conversation = waiting_conversation
      @online = {}

      processor.process(inbox.id)

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_present
    end
  end

  describe 'blocker #2a: registrar closes the trigger-before-marker race' do
    it 'enqueues a coalesced pass for the inbox after writing the marker' do
      allow(process_job).to receive(:enqueue_for_inbox)

      conversation = waiting_conversation

      expect(marker_for(conversation)).to be_present
      expect(process_job).to have_received(:enqueue_for_inbox).with(inbox.id)
    end
  end

  describe 'blocker #2b: in-flight rerun handshake (no lost wakeup, no storm)' do
    let(:in_flight_key) { format(process_job::IN_FLIGHT_KEY, inbox_id: inbox.id) }
    let(:rerun_key) { format(process_job::RERUN_KEY, inbox_id: inbox.id) }

    before do
      Redis::Alfred.delete(in_flight_key)
      Redis::Alfred.delete(rerun_key)
    end

    after do
      Redis::Alfred.delete(in_flight_key)
      Redis::Alfred.delete(rerun_key)
    end

    it 'records a rerun request when a trigger is coalesced against an in-flight job' do
      Redis::Alfred.set(in_flight_key, 'held-by-another-job', ex: 300)

      expect(process_job.enqueue_for_inbox(inbox.id)).to be(false)
      expect(Redis::Alfred.get(rerun_key)).to eq('1')
    end

    it 'consumes a pending rerun on release and enqueues exactly one more pass' do
      allow(processor).to receive(:process)
      allow(process_job).to receive(:perform_later).and_return(true)
      Redis::Alfred.set(in_flight_key, 'my-token', ex: 300)
      Redis::Alfred.set(rerun_key, '1', ex: 300)

      process_job.perform_now(inbox_id: inbox.id, token: 'my-token')

      expect(process_job).to have_received(:perform_later).with(hash_including(inbox_id: inbox.id))
      expect(Redis::Alfred.get(rerun_key)).to be_nil
    end

    it 'does not re-enqueue when no rerun request is pending' do
      allow(processor).to receive(:process)
      allow(process_job).to receive(:perform_later).and_return(true)
      Redis::Alfred.set(in_flight_key, 'my-token', ex: 300)

      process_job.perform_now(inbox_id: inbox.id, token: 'my-token')

      expect(process_job).not_to have_received(:perform_later)
    end
  end

  describe 'blocker #3a: freed capacity recovers a waiting conversation' do
    it 'enqueues a marker-gated recovery pass when a previously assigned conversation is resolved' do
      agent = make_agent
      waiting_conversation # marks the inbox
      assigned = create(:conversation, account: account, inbox: inbox, assignee: agent, status: :open)
      allow(trigger_service).to receive(:enqueue_for_inbox)

      assigned.update!(status: :resolved)

      expect(trigger_service).to have_received(:enqueue_for_inbox).with(inbox.id)
    end

    it 'enqueues a recovery pass when a previously assigned conversation is reassigned away' do
      agent = make_agent
      other = make_agent
      assigned = create(:conversation, account: account, inbox: inbox, assignee: agent, status: :open)
      allow(trigger_service).to receive(:enqueue_for_inbox)

      assigned.update!(assignee: other)

      expect(trigger_service).to have_received(:enqueue_for_inbox).with(inbox.id)
    end

    it 'does not run recovery on a first assignment (no prior assignee occupied capacity)' do
      agent = make_agent
      conversation = waiting_conversation
      allow(trigger_service).to receive(:enqueue_for_inbox)

      conversation.update!(assignee: agent)

      expect(trigger_service).not_to have_received(:enqueue_for_inbox)
    end
  end

  describe 'blocker #3b: a new inbox member reprocesses the inbox (marker-gated)' do
    it 'enqueues a pass when the inbox already holds a marker' do
      waiting_conversation
      allow(process_job).to receive(:enqueue_for_inbox)

      create(:inbox_member, inbox: inbox, user: create(:user, account: account, role: :agent))

      expect(process_job).to have_received(:enqueue_for_inbox).with(inbox.id)
    end

    it 'does not enqueue when the inbox holds no marker' do
      allow(process_job).to receive(:enqueue_for_inbox)

      create(:inbox_member, inbox: inbox, user: create(:user, account: account, role: :agent))

      expect(process_job).not_to have_received(:enqueue_for_inbox)
    end
  end

  describe 'blocker #3c: a new team member reprocesses the team-marked inboxes' do
    let(:team) { create(:team, account: account, allow_auto_assign: true) }

    it 'enqueues for an inbox holding a marker routed to that team (stored team_id)' do
      make_agent(team: team)
      waiting_conversation(team: team)
      allow(process_job).to receive(:enqueue_for_inbox)

      create(:team_member, team: team, user: create(:user, account: account, role: :agent))

      expect(process_job).to have_received(:enqueue_for_inbox).with(inbox.id)
    end

    it 'does not enqueue when no marker is routed to that team' do
      other_team = create(:team, account: account, allow_auto_assign: true)
      waiting_conversation(team: other_team)
      allow(process_job).to receive(:enqueue_for_inbox)

      create(:team_member, team: team, user: create(:user, account: account, role: :agent))

      expect(process_job).not_to have_received(:enqueue_for_inbox)
    end
  end

  describe 'blocker #6: parent deletion cascades markers at the DB level' do
    it 'removes the marker when the conversation row is deleted directly (bypassing the dependent callback)' do
      conversation = waiting_conversation
      marker_id = marker_for(conversation).id

      # delete_all issues a raw DELETE that never fires has_one dependent: :destroy, mirroring
      # core paths (destroy_async / delete_all). Only the FK on_delete: :cascade can clean up.
      Conversation.where(id: conversation.id).delete_all

      expect(Wijaya::Batteries::DeferredAutoAssignment::Marker.exists?(marker_id)).to be(false)
    end
  end
end
