# frozen_string_literal: true

require 'rails_helper'

# Durable deletion provenance for the deferred auto-assignment battery. When Agents::DestroyJob
# deletes an agent it records a structured tombstone (account, conversation, inbox, prior human
# agent id, event kind + time) ATOMICALLY inside the unassignment transaction, so a crash before
# the existing post-commit dispatch can be reconciled later from an authoritative source instead
# of guessed from free-text activity. Recording is savepoint-isolated and fail-open: it can never
# roll back the user deletion. It stores no message content and survives the agent's deletion.
RSpec.describe 'Deferred auto-assignment deletion provenance', type: :model do
  let(:provenance_model) { Wijaya::Batteries::DeferredAutoAssignment::DeletionProvenance }
  let(:recorder) { Wijaya::Batteries::DeferredAutoAssignment::ProvenanceRecorder }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  before do
    account.disable_features!(:assignment_v2) # legacy battery path; assignment_v2 now defaults on
    # Keep the post-commit reassignment pipeline inert; this spec is about provenance recording.
    allow(Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob).to receive(:enqueue_for_inbox)
    allow(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox)
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})
  end

  def make_agent
    user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: user)
    user
  end

  def conversation_assigned_to(agent, params = {})
    Conversation.create!({ account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: agent }.merge(params))
  end

  def provenance_for(conversation)
    provenance_model.where(conversation_id: conversation.id)
  end

  describe 'recording during an agent deletion' do
    it 'records a structured tombstone for exactly the cleared conversation' do
      agent = make_agent
      conversation = conversation_assigned_to(agent)

      Agents::DestroyJob.perform_now(account, agent)

      row = provenance_for(conversation).first
      expect(row).to be_present
      expect(row.account_id).to eq(account.id)
      expect(row.inbox_id).to eq(inbox.id)
      expect(row.prior_assignee_id).to eq(agent.id)
      expect(row.event).to eq('agent_deletion')
      expect(row.event_at).to be_present
      expect(row.reconciled_at).to be_nil
    end

    it 'records nothing for a conversation that did not belong to the deleted agent' do
      agent = make_agent
      other = make_agent
      untouched = conversation_assigned_to(other)

      Agents::DestroyJob.perform_now(account, agent)

      expect(provenance_for(untouched)).to be_empty
    end

    it 'survives the prior agent’s User + membership deletion (no cascading FK erases it)' do
      agent = make_agent
      conversation = conversation_assigned_to(agent)
      Agents::DestroyJob.perform_now(account, agent)

      # Fully remove the agent as the real flow eventually does.
      AccountUser.where(account_id: account.id, user_id: agent.id).delete_all
      User.where(id: agent.id).delete_all

      row = provenance_for(conversation).first
      expect(row).to be_present
      expect(row.prior_assignee_id).to eq(agent.id)
    end
  end

  describe 'idempotency' do
    it 'records exactly one tombstone across a retried DestroyJob' do
      agent = make_agent
      conversation = conversation_assigned_to(agent)

      Agents::DestroyJob.perform_now(account, agent)
      # A retry finds the agent owns no conversations, so nothing new is recorded.
      Agents::DestroyJob.perform_now(account, agent)

      expect(provenance_for(conversation).count).to eq(1)
    end

    it 'never double-records when the SAME deletion (same deletion_key) is re-dispatched' do
      agent = make_agent
      conversation = conversation_assigned_to(agent)
      conversation.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations

      recorder.record_agent_deletion(account.id, agent.id, [conversation.id], deletion_key: 'job-1')
      recorder.record_agent_deletion(account.id, agent.id, [conversation.id], deletion_key: 'job-1')

      expect(provenance_for(conversation).count).to eq(1)
    end
  end

  # Blocker B: distinct deletion occurrences of the same conversation+agent must NOT be collapsed by
  # the uniqueness key; a retry of one occurrence dedupes, a genuinely later removal records anew.
  describe 'per-deletion-occurrence idempotency key (deletion_key)' do
    it 'dedupes retries of the SAME deletion but records a DISTINCT later delete/re-add/delete' do
      agent = make_agent
      conversation = conversation_assigned_to(agent)
      conversation.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations

      # First deletion occurrence + its retry (same job_id) => one row.
      recorder.record_agent_deletion(account.id, agent.id, [conversation.id], deletion_key: 'delete-1')
      recorder.record_agent_deletion(account.id, agent.id, [conversation.id], deletion_key: 'delete-1')
      expect(provenance_for(conversation).count).to eq(1)

      # Re-add + a genuinely NEW deletion occurrence (new job_id) => a second, distinct tombstone.
      recorder.record_agent_deletion(account.id, agent.id, [conversation.id], deletion_key: 'delete-2')
      expect(provenance_for(conversation).count).to eq(2)
      expect(provenance_for(conversation).pluck(:deletion_key)).to contain_exactly('delete-1', 'delete-2')
    end

    it 'recovers the SECOND occurrence after a crash between its two recordings (retry re-records once)' do
      agent = make_agent
      conversation = conversation_assigned_to(agent)
      conversation.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations

      recorder.record_agent_deletion(account.id, agent.id, [conversation.id], deletion_key: 'occ-1')
      # A second occurrence begins; simulate a crash by having its FIRST recording raise mid-write,
      # then a retry of the SAME occurrence completes it — exactly one new row, never zero, never two.
      calls = 0
      allow(recorder).to receive(:upsert_row).and_wrap_original do |orig, *args|
        calls += 1
        raise StandardError, 'crash mid-record' if calls == 1

        orig.call(*args)
      end
      expect do
        recorder.record_agent_deletion(account.id, agent.id, [conversation.id], deletion_key: 'occ-2')
      end.to raise_error(StandardError, /crash/)
      expect(provenance_for(conversation).count).to eq(1) # savepoint rolled back the partial second write

      # Retry of the SAME second occurrence (same deletion_key) completes it exactly once.
      recorder.record_agent_deletion(account.id, agent.id, [conversation.id], deletion_key: 'occ-2')
      expect(provenance_for(conversation).count).to eq(2)
      expect(provenance_for(conversation).pluck(:deletion_key)).to contain_exactly('occ-1', 'occ-2')
    end
  end

  describe 'cross-account safety' do
    it 'records only account-scoped ids and ignores a stray cross-account id' do
      agent = make_agent
      mine = conversation_assigned_to(agent)

      other_account = create(:account)
      other_inbox = create(:inbox, account: other_account, enable_auto_assignment: true)
      other_contact = create(:contact, account: other_account)
      cross = create(:conversation, account: other_account, inbox: other_inbox, contact: other_contact,
                                    contact_inbox: create(:contact_inbox, contact: other_contact, inbox: other_inbox))

      recorder.record_agent_deletion(account.id, agent.id, [mine.id, cross.id], deletion_key: 'job-x')

      expect(provenance_for(mine).count).to eq(1)
      expect(provenance_for(cross)).to be_empty
    end
  end

  describe 'fail-open: recording never rolls back the user deletion' do
    it 'still unassigns the conversation when provenance recording raises' do
      agent = make_agent
      conversation = conversation_assigned_to(agent)
      allow(recorder).to receive(:record_agent_deletion).and_raise(StandardError)

      expect { Agents::DestroyJob.perform_now(account, agent) }.not_to raise_error

      expect(conversation.reload.assignee_id).to be_nil
      expect(provenance_for(conversation)).to be_empty
    end
  end
end
