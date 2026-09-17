# frozen_string_literal: true

require 'rails_helper'

# Agent-deletion bridge for the deferred auto-assignment battery. Agents::DestroyJob clears
# the deleted agent's assignee_id with update_all (callbacks skipped), leaving those
# conversations open + unassigned. A post-commit bridge hands exactly those conversations to
# the battery, which re-runs native legacy auto-assignment: each still-eligible one is marked
# and processed (assigned to an eligible online agent now via the UNCHANGED native selector,
# or left marked for a later trigger). Only the deleted agent's conversations are touched —
# never an account-wide scan.
RSpec.describe 'Deferred auto-assignment agent-deletion bridge', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  # Deterministic, Redis-free round-robin: pick the FIRST id from the online∩allowed set the
  # native AgentAssignmentService hands us (proves the candidate SET, not Redis ordering).
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
    account.disable_features!(:assignment_v2) # legacy battery path; assignment_v2 now defaults on
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

  def marker_for(conversation)
    Wijaya::Batteries::DeferredAutoAssignment::Marker.find_by(conversation_id: conversation.id)
  end

  # Open conversation already assigned to +agent+ (no marker — assignee present at creation).
  def conversation_assigned_to(agent, params = {})
    @online = []
    Conversation.create!({ account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: agent }.merge(params))
  end

  def delete_agent(agent)
    Agents::DestroyJob.perform_now(account, agent)
  end

  describe 'the bridge marks the deleted agent’s unassigned conversations' do
    it 'unassigns Agent A’s conversation and records a deferred marker for it' do
      agent_a = make_agent
      conversation = conversation_assigned_to(agent_a)
      expect(marker_for(conversation)).to be_nil

      delete_agent(agent_a)

      expect(conversation.reload.assignee_id).to be_nil
      marker = marker_for(conversation)
      expect(marker).to be_present
      expect(marker.inbox_id).to eq(inbox.id)
      expect(marker.account_id).to eq(account.id)
    end

    it 'never marks a conversation that did not belong to the deleted agent (no account-wide scan)' do
      agent_a = make_agent
      other_agent = make_agent
      mine = conversation_assigned_to(agent_a)
      untouched = conversation_assigned_to(other_agent)

      delete_agent(agent_a)

      expect(marker_for(mine)).to be_present
      expect(untouched.reload.assignee_id).to eq(other_agent.id)
      expect(marker_for(untouched)).to be_nil
    end
  end

  describe 'reassignment through the native selector' do
    # Drive the REAL async pipeline: the bridge enqueues ProcessInboxJob after commit, and we
    # let ActiveJob perform exactly that job (not a manual InboxProcessor call) so the queued
    # pass is what assigns. Only the native round-robin picker is mocked for deterministic
    # selection; the marker/eligibility/assignment pipeline runs unmocked.
    def run_deletion_pipeline(agent)
      perform_enqueued_jobs(only: Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob) do
        delete_agent(agent)
      end
    end

    it 'reassigns to an eligible online agent B via the queued ProcessInboxJob and clears the marker' do
      agent_a = make_agent
      agent_b = make_agent
      conversation = conversation_assigned_to(agent_a)

      @online = [agent_b.id.to_s] # B is reachable at deletion time
      run_deletion_pipeline(agent_a)

      expect(conversation.reload.assignee).to eq(agent_b)
      expect(marker_for(conversation)).to be_nil
    end

    it 'keeps the marker (still unassigned) when no eligible agent is available yet' do
      agent_a = make_agent
      make_agent # an inbox member exists but is offline
      conversation = conversation_assigned_to(agent_a)

      @online = [] # nobody online when the queued job runs
      run_deletion_pipeline(agent_a)

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_present
    end

    it 'enqueues a coalesced processing pass for the affected inbox' do
      agent_a = make_agent
      make_agent
      conversation_assigned_to(agent_a)

      expect(Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob).to receive(:enqueue_for_inbox).with(inbox.id)

      delete_agent(agent_a)
    end
  end

  describe 'eligibility is respected' do
    let(:team) { create(:team, account: account, allow_auto_assign: true) }

    it 'assigns the online inbox∩team member and excludes an online inbox-only member' do
      agent_a = make_agent(team: team)
      team_agent = make_agent(team: team)
      outside_agent = make_agent(team: nil) # inbox member, NOT a team member
      conversation = conversation_assigned_to(agent_a, team: team)

      delete_agent(agent_a)

      @online = [team_agent.id.to_s, outside_agent.id.to_s]
      Wijaya::Batteries::DeferredAutoAssignment::InboxProcessor.process(inbox.id)

      expect(conversation.reload.assignee).to eq(team_agent)
    end

    it 'records no marker when native auto-assignment is not applicable (inbox toggle off)' do
      agent_a = make_agent
      make_agent
      inbox.update!(enable_auto_assignment: false)
      conversation = conversation_assigned_to(agent_a)

      delete_agent(agent_a)

      expect(marker_for(conversation)).to be_nil
    end

    # Capacity filtering (member_ids_with_assignment_capacity) is Enterprise-only; the CE build
    # never excludes an over-capacity agent, so this can only be exercised with enterprise/.
    it 'keeps the marker when the only online agent has no assignment capacity', :enterprise do
      agent_a = make_agent
      agent_b = make_agent
      inbox.update!(auto_assignment_config: { 'max_assignment_limit' => 1 })
      create(:conversation, account: account, inbox: inbox, assignee: agent_b, status: :open)
      conversation = conversation_assigned_to(agent_a)

      delete_agent(agent_a)

      @online = [agent_b.id.to_s]
      Wijaya::Batteries::DeferredAutoAssignment::InboxProcessor.process(inbox.id)

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_present
    end
  end

  describe 'exclusions and race protection' do
    it 'excludes an agent-bot–owned conversation (bot/system handled)' do
      agent_a = make_agent
      make_agent
      agent_bot = create(:agent_bot, account: account)
      conversation = conversation_assigned_to(agent_a)
      # An agent bot owns the conversation (set without callbacks, mirroring processing_spec).
      conversation.update_column(:assignee_agent_bot_id, agent_bot.id) # rubocop:disable Rails/SkipsModelValidations

      delete_agent(agent_a)

      expect(marker_for(conversation)).to be_nil
    end

    it 'never overwrites a manual assignment made after the deletion' do
      agent_a = make_agent
      agent_b = make_agent
      spv_agent = make_agent
      conversation = conversation_assigned_to(agent_a)

      delete_agent(agent_a)
      expect(marker_for(conversation)).to be_present

      # A supervisor manually claims the conversation before processing; the concern’s
      # after_update_commit lifecycle drops the now-stale marker immediately.
      conversation.update!(assignee: spv_agent)
      expect(marker_for(conversation)).to be_nil

      @online = [agent_b.id.to_s]
      Wijaya::Batteries::DeferredAutoAssignment::InboxProcessor.process(inbox.id)

      expect(conversation.reload.assignee).to eq(spv_agent)
    end
  end

  describe 'idempotency across a retried deletion (DestroyJob run twice)' do
    def marker_count(conversation)
      Wijaya::Batteries::DeferredAutoAssignment::Marker.where(conversation_id: conversation.id).count
    end

    it 'records exactly one marker and never a duplicate when the destroy job runs twice' do
      agent_a = make_agent
      make_agent # an offline inbox member, so the marker stays for a later trigger
      conversation = conversation_assigned_to(agent_a)

      delete_agent(agent_a)
      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_count(conversation)).to eq(1)

      # A retried DestroyJob for the same (already-deleted) agent finds no assigned
      # conversations, so the bridge collects no ids and cannot double-mark.
      expect { delete_agent(agent_a) }.not_to(change { marker_count(conversation) })
      expect(marker_count(conversation)).to eq(1)
    end

    it 'never overwrites a manual assignment made between the two destroy-job runs' do
      agent_a = make_agent
      spv_agent = make_agent
      conversation = conversation_assigned_to(agent_a)

      delete_agent(agent_a)
      expect(marker_for(conversation)).to be_present

      # A supervisor claims the conversation; the concern's after_update_commit lifecycle
      # drops the now-stale marker.
      conversation.update!(assignee: spv_agent)
      expect(marker_for(conversation)).to be_nil

      # The retried deletion must not re-mark or disturb the manual assignment.
      delete_agent(agent_a)

      expect(conversation.reload.assignee).to eq(spv_agent)
      expect(marker_for(conversation)).to be_nil
    end

    # Lower-level guard for the crash-retry path where the SAME ids are re-dispatched to the
    # bridge (e.g. the job is retried before the unassignment scope goes empty): the unique
    # conversation_id keeps find_or_create_by! from producing a duplicate marker.
    it 'creates a single marker when the same conversation ids are dispatched twice' do
      agent_a = make_agent
      conversation = conversation_assigned_to(agent_a)
      conversation.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations

      registrar = Wijaya::Batteries::DeferredAutoAssignment::Registrar
      registrar.register_unassigned_after_agent_deletion(account.id, [conversation.id])
      registrar.register_unassigned_after_agent_deletion(account.id, [conversation.id])

      expect(marker_count(conversation)).to eq(1)
    end
  end
end
