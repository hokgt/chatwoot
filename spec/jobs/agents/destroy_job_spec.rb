require 'rails_helper'

RSpec.describe Agents::DestroyJob do
  subject(:job) { described_class.perform_later(account, user) }

  let!(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:team1) { create(:team, account: account) }
  let!(:inbox) { create(:inbox, account: account) }

  before do
    create(:team_member, team: team1, user: user)
    create(:inbox_member, inbox: inbox, user: user)
    create(:conversation, account: account, assignee: user, inbox: inbox)
  end

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(account, user)
      .on_queue('low')
  end

  describe '#perform' do
    it 'remove inboxes, teams, and conversations when removed from account' do
      described_class.perform_now(account, user)

      user.reload
      expect(user.teams.length).to eq 0
      expect(user.inboxes.length).to eq 0
      expect(user.notification_settings.length).to eq 0
      expect(user.assigned_conversations.where(account: account).length).to eq 0
    end
  end

  # WIJAYA deferred_auto_assignment — blocker A: the unassignment row-locks (FOR UPDATE) the deleted
  # agent's conversations and records provenance / clears / dispatches EXACTLY that locked set, so a
  # concurrent manual reassignment can never leave a tombstone for — or clobber — a conversation the
  # deletion did not actually unassign.
  describe 'manual reassignment / ownership-change race' do
    let(:provenance_model) { Wijaya::Batteries::DeferredAutoAssignment::DeletionProvenance }
    let(:marker_model) { Wijaya::Batteries::DeferredAutoAssignment::Marker }
    let(:contact) { create(:contact, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

    before do
      account.disable_features!(:assignment_v2) # legacy battery path; assignment_v2 defaults on
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})
      allow(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox)
      allow(Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob).to receive(:enqueue_for_inbox)
    end

    def make_agent
      agent = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: inbox, user: agent)
      agent
    end

    def conversation_for(agent)
      Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: agent)
    end

    it 'row-locks the deleted agent’s conversations with FOR UPDATE' do
      agent = make_agent
      expect(agent.assigned_conversations.where(account: account).lock.to_sql).to include('FOR UPDATE')
    end

    it 'never records/clears/adopts a conversation reassigned to a different agent in the lock window' do
      agent_a = make_agent
      agent_b = make_agent
      conversation = conversation_for(agent_a)

      # Model a manual reassignment that lands right AFTER the FOR UPDATE capture but BEFORE the
      # conditional clear: the deleted agent's own conversation moves to a different current assignee.
      job = described_class.new
      allow(job).to receive(:wijaya_lock_assigned_conversation_ids).and_wrap_original do |orig, acc, usr|
        ids = orig.call(acc, usr)
        conversation.update!(assignee: agent_b) if ids.include?(conversation.id)
        ids
      end

      job.perform(account, agent_a)

      expect(conversation.reload.assignee).to eq(agent_b)                          # not clobbered
      expect(provenance_model.where(conversation_id: conversation.id)).to be_empty # no FALSE provenance
      expect(marker_model.find_by(conversation_id: conversation.id)).to be_nil     # not adopted
    end

    it 'never touches a conversation currently owned by a different agent (ownership scoping)' do
      agent_a = make_agent
      agent_b = make_agent
      mine = conversation_for(agent_a)
      theirs = conversation_for(agent_b)

      described_class.perform_now(account, agent_a)

      expect(mine.reload.assignee_id).to be_nil                                    # cleared...
      expect(provenance_model.where(conversation_id: mine.id).count).to eq(1)      # ...and recorded
      expect(theirs.reload.assignee).to eq(agent_b)                               # untouched
      expect(provenance_model.where(conversation_id: theirs.id)).to be_empty       # not recorded
      expect(marker_model.find_by(conversation_id: theirs.id)).to be_nil           # not adopted
    end
  end
end
