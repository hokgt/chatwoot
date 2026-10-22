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
    let(:unassignment_service) { Wijaya::Batteries::DeferredAutoAssignment::AgentDeletionUnassignment }
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
      # The battery service locks exactly this relation (account + still-assigned to the agent).
      relation = Conversation.where(account_id: account.id, assignee_id: agent.id).lock
      expect(relation.to_sql).to include('FOR UPDATE')
    end

    it 'never records/clears/adopts a conversation reassigned to a different agent in the lock window' do
      agent_a = make_agent
      agent_b = make_agent
      conversation = conversation_for(agent_a)

      # Model a manual reassignment that lands right AFTER the FOR UPDATE capture but BEFORE the
      # conditional clear: the deleted agent's own conversation moves to a different current assignee.
      allow(unassignment_service).to receive(:lock_assigned_conversation_ids).and_wrap_original do |orig, account_id, user_id|
        ids = orig.call(account_id, user_id)
        conversation.update!(assignee: agent_b) if ids.include?(conversation.id)
        ids
      end

      described_class.perform_now(account, agent_a)

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

  # WIJAYA deferred_auto_assignment — the deletion race fix: the final orphaned-User deletion is
  # serialized at the TAIL of this job (after the provenance/unassignment transaction commits and
  # the reassignment bridge dispatches), gated by the caller's intent + a membership recheck. This
  # replaces the controller's sibling DeleteObjectJob that could FK-clear assignee_id before
  # provenance was captured.
  describe 'serialized final user deletion (race fix)' do
    include ActiveJob::TestHelper

    let(:provenance_model) { Wijaya::Batteries::DeferredAutoAssignment::DeletionProvenance }
    let(:marker_model) { Wijaya::Batteries::DeferredAutoAssignment::Marker }
    let(:contact) { create(:contact, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

    before do
      account.disable_features!(:assignment_v2) # legacy battery path; assignment_v2 defaults on
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})
      allow(Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob).to receive(:enqueue_for_inbox)
    end

    # Mirror production ordering: the account membership is already destroyed (by the controller)
    # when Agents::DestroyJob runs, so the finalizer's blank?-membership recheck is meaningful.
    def remove_account_membership
      user.account_users.find_by(account: account).destroy!
    end

    # Ordering proof that does NOT rely only on final state: spy on the DeleteObjectJob enqueue and
    # assert that AT THE MOMENT it is enqueued the provenance row and marker already exist — i.e. the
    # deletion is the strict tail, after provenance capture and the reassignment-bridge dispatch.
    it 'enqueues the User deletion only at the tail, after provenance + marker already exist' do
      conversation = Conversation.create!(account: account, inbox: inbox, contact: contact,
                                          contact_inbox: contact_inbox, assignee: user)
      remove_account_membership

      provenance_at_enqueue = nil
      marker_at_enqueue = nil
      allow(DeleteObjectJob).to receive(:perform_later).and_wrap_original do |orig, *args|
        provenance_at_enqueue = provenance_model.where(conversation_id: conversation.id).count
        marker_at_enqueue = marker_model.exists?(conversation_id: conversation.id)
        orig.call(*args)
      end

      described_class.perform_now(account, user, delete_user_when_orphaned: true)

      expect(provenance_at_enqueue).to eq(1)                     # provenance captured BEFORE the enqueue
      expect(marker_at_enqueue).to be(true)                      # marker dispatched BEFORE the enqueue
      expect(DeleteObjectJob).to have_received(:perform_later).with(user).once
      expect(User.exists?(user.id)).to be(true)                 # only ENQUEUED here, not yet destroyed
    end

    it 'does not enqueue the User deletion without the explicit intent (account teardown / platform APIs)' do
      remove_account_membership

      expect { described_class.perform_now(account, user) }.not_to have_enqueued_job(DeleteObjectJob)
      expect { described_class.perform_now(account, user, delete_user_when_orphaned: false) }.not_to have_enqueued_job(DeleteObjectJob)
      expect(User.exists?(user.id)).to be(true)
    end

    it 'never deletes a user who still belongs to another account' do
      create(:account_user, account: create(:account), user: user)
      remove_account_membership

      expect { described_class.perform_now(account, user, delete_user_when_orphaned: true) }.not_to have_enqueued_job(DeleteObjectJob)
      expect(user.reload.account_users.count).to eq(1)
    end

    # Native fallback: with the battery hook unavailable the job MUST still delete the orphaned User
    # (upstream deletion semantics), and must enqueue exactly one DeleteObjectJob (no double enqueue).
    it 'falls back to a native DeleteObjectJob when the battery finalizer hook is unavailable' do
      remove_account_membership
      allow(Wijaya::Batteries::Core::Hooks).to receive(:dispatch).and_call_original
      allow(Wijaya::Batteries::Core::Hooks).to receive(:dispatch)
        .with(:deferred_auto_assignment, :finalize_orphaned_user_deletion, any_args)
        .and_return(false)

      expect { described_class.perform_now(account, user, delete_user_when_orphaned: true) }
        .to have_enqueued_job(DeleteObjectJob).with(user).exactly(:once)
    end

    # Idempotency BEFORE the final deletion: a retried DestroyJob (User still present, now owning
    # nothing) records no duplicate provenance. Idempotency AFTER the deletion is at the DeleteObjectJob
    # layer — see the discard test below — NOT a "harmless no-op re-enqueue".
    it 'records no duplicate provenance when the whole job is retried before the User is deleted' do
      conversation = Conversation.create!(account: account, inbox: inbox, contact: contact,
                                          contact_inbox: contact_inbox, assignee: user)
      remove_account_membership

      described_class.perform_now(account, user, delete_user_when_orphaned: true)
      expect { described_class.perform_now(account, user, delete_user_when_orphaned: true) }
        .not_to(change { provenance_model.where(conversation_id: conversation.id).count })
      expect(provenance_model.where(conversation_id: conversation.id).count).to eq(1)
    end

    # Accurate post-deletion behaviour (correcting the old "re-enqueues a harmless no-op" claim):
    # once DeleteObjectJob has destroyed the User, a stale retry cannot deserialize the GlobalID and
    # is DISCARDED by ApplicationJob's discard_on ActiveJob::DeserializationError — no error, no
    # double-delete, and it is NOT re-run as a no-op.
    it 'discards a stale DeleteObjectJob retry once the User is gone (GlobalID deserialization)' do
      remove_account_membership
      perform_enqueued_jobs { described_class.perform_now(account, user, delete_user_when_orphaned: true) }
      expect(User.exists?(user.id)).to be(false)

      expect { perform_enqueued_jobs { DeleteObjectJob.perform_later(user) } }.not_to raise_error
    end
  end

  # WIJAYA deferred_auto_assignment — the heavy lock/clear/provenance logic lives in the battery
  # service; the core job keeps only a tiny fail-open dispatch. When the battery hook is
  # unavailable/fails, the dispatcher returns nil and the job falls back to the original native
  # unassignment (still clearing the agent's conversations) WITHOUT dispatching any guessed
  # post-commit ids to the reassignment bridge.
  describe 'fail-open fallback when the battery is unavailable' do
    let(:provenance_model) { Wijaya::Batteries::DeferredAutoAssignment::DeletionProvenance }
    let(:unassignment_service) { Wijaya::Batteries::DeferredAutoAssignment::AgentDeletionUnassignment }
    let(:contact) { create(:contact, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

    before { account.disable_features!(:assignment_v2) }

    def make_agent
      agent = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: inbox, user: agent)
      agent
    end

    it 'still unassigns natively and never dispatches guessed post-commit ids when the hook fails' do
      agent = make_agent
      conversation = Conversation.create!(account: account, inbox: inbox, contact: contact,
                                          contact_inbox: contact_inbox, assignee: agent)
      allow(unassignment_service).to receive(:unassign).and_raise(StandardError)
      expect(Wijaya::Batteries::DeferredAutoAssignment::Registrar)
        .not_to receive(:register_unassigned_after_agent_deletion)

      expect { described_class.perform_now(account, agent) }.not_to raise_error

      expect(conversation.reload.assignee_id).to be_nil                            # native fallback cleared it
      expect(provenance_model.where(conversation_id: conversation.id)).to be_empty # no tombstone (best-effort)
    end
  end
end
