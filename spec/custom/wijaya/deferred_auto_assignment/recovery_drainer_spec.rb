# frozen_string_literal: true

require 'rails_helper'

# Recovery drainer for the deferred auto-assignment battery. It is the durable-outbox / crash-gap
# FALLBACK (NOT the primary future deletion mechanism, which stays Agents::DestroyJob -> Registrar):
# a low-frequency, self-gating scan of ONLY unreconciled DeletionProvenance tombstones older than a
# safety age, enqueuing the EXACT existing ReconciliationJob (with a fresh generation + safety-age
# cutoff) to adopt any straggler through the unchanged native pipeline. It never scans all Unassigned
# conversations, never writes assignee_id directly, and no-ops (no run, no job) when nothing is due.
RSpec.describe 'Deferred auto-assignment recovery drainer', type: :model do
  let(:provenance_model) { Wijaya::Batteries::DeferredAutoAssignment::DeletionProvenance }
  let(:run_model) { Wijaya::Batteries::DeferredAutoAssignment::ReconciliationRun }
  let(:marker_model) { Wijaya::Batteries::DeferredAutoAssignment::Marker }
  let(:reconciler) { Wijaya::Batteries::DeferredAutoAssignment::Reconciler }
  let(:drainer) { Wijaya::Batteries::DeferredAutoAssignment::RecoveryDrainerJob }
  let(:recon_job) { Wijaya::Batteries::DeferredAutoAssignment::ReconciliationJob }
  let(:process_inbox_job) { Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob }
  let(:erp_owner_sync_job) { Wijaya::Batteries::ErpLeadOwnerSync::OwnerSyncJob }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  # Deterministic, Redis-free round-robin: pick the FIRST id from the online∩allowed set.
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
    allow(erp_owner_sync_job).to receive(:perform_later)
  end

  def make_agent
    user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: user)
    user
  end

  def marker_for(conversation)
    marker_model.find_by(conversation_id: conversation.id)
  end

  def provenance_row(conversation)
    provenance_model.find_by(conversation_id: conversation.id)
  end

  # A crash-gap orphan: assignee cleared by an agent deletion, WITH a durable provenance tombstone
  # but NO marker and no trigger (the SIGKILL-after-commit-before-dispatch case). Backdated so both
  # event_at AND created_at sit before the drainer's safety-age cutoff, exactly as in production.
  def crash_gap_orphan(event_at: 1.hour.ago)
    @online = []
    prior = create(:user, account: account, role: :agent)
    conversation = Conversation.create!(
      account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: prior
    )
    # rubocop:disable Rails/SkipsModelValidations
    conversation.update_column(:assignee_id, nil)
    conversation.update_column(:created_at, event_at - 1.hour) # created before the deletion event
    # rubocop:enable Rails/SkipsModelValidations
    reset_clean_pre_feature_state(conversation)
    provenance_model.create!(
      account: account, conversation: conversation, inbox: inbox,
      prior_assignee_id: prior.id, event: 'agent_deletion', event_at: event_at
    )
    AccountUser.where(account_id: account.id, user_id: prior.id).delete_all # structurally confirm deletion
    [conversation, prior]
  end

  # No creation-time marker and no lingering in-flight/rerun key that would coalesce the enqueue away.
  def reset_clean_pre_feature_state(conversation)
    marker_model.where(conversation_id: conversation.id).delete_all
    Redis::Alfred.delete(format(process_inbox_job::IN_FLIGHT_KEY, inbox_id: conversation.inbox_id))
    Redis::Alfred.delete(format(process_inbox_job::RERUN_KEY, inbox_id: conversation.inbox_id))
  end

  # Run the drainer and cascade the reconciliation + per-inbox assignment it enqueues.
  def run_drainer
    perform_enqueued_jobs(only: [recon_job, process_inbox_job]) { drainer.perform_now }
  end

  describe 'a post-commit crash-gap provenance row is later automatically recovered' do
    it 'registers and assigns the orphan through the existing pipeline, then stamps it reconciled' do
      agent = make_agent
      conversation, = crash_gap_orphan
      @online = [agent.id.to_s]
      expect(marker_for(conversation)).to be_nil

      run_drainer

      expect(conversation.reload.assignee).to eq(agent)
      expect(marker_for(conversation)).to be_nil                       # resolved after assignment
      expect(provenance_row(conversation).reconciled_at).to be_present
      expect(run_model.count).to eq(1)
      run = run_model.first
      expect(run.registered).to eq(1)
      expect(run.assigned).to eq(1)
    end

    it 'retains the marker (no_eligible_agent) when no agent is online, for a later trigger' do
      make_agent # an offline inbox member exists
      conversation, = crash_gap_orphan
      @online = []

      run_drainer

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_present
      expect(run_model.first.registered).to eq(1)
      expect(run_model.first.no_eligible_agent).to eq(1)
    end
  end

  describe 'self-gating: it never runs when nothing is due' do
    it 'does nothing — no run, no ReconciliationJob — when there is no provenance at all' do
      make_agent
      expect(provenance_model.count).to eq(0)
      expect(recon_job).not_to receive(:perform_later)

      expect { drainer.perform_now }.not_to change(run_model, :count)
    end

    it 'does not drain provenance younger than the safety age (never races the live bridge)' do
      make_agent
      crash_gap_orphan(event_at: 1.minute.ago) # inside the SAFETY_AGE window
      expect(recon_job).not_to receive(:perform_later)

      expect { drainer.perform_now }.not_to change(run_model, :count)
    end
  end

  describe 'it scans ONLY provenance, never intentional Unassigned conversations' do
    it 'never scans or touches an intentionally-unassigned conversation that has no provenance row' do
      make_agent
      intentional = Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      intentional.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations
      marker_model.where(conversation_id: intentional.id).delete_all
      @online = [make_agent.id.to_s]

      expect(recon_job).not_to receive(:perform_later)
      run_drainer

      expect(intentional.reload.assignee_id).to be_nil
      expect(marker_for(intentional)).to be_nil
      expect(run_model.count).to eq(0)
    end
  end

  describe 'idempotency under duplicate / concurrent invocations' do
    it 'is a no-op on a second sequential tick (rows already stamped reconciled): one run, one assignment' do
      agent = make_agent
      conversation, = crash_gap_orphan
      @online = [agent.id.to_s]

      run_drainer                                # first tick adopts + assigns + stamps reconciled
      expect { run_drainer }.not_to change(run_model, :count) # second tick finds nothing unreconciled

      expect(conversation.reload.assignee).to eq(agent)
      expect(marker_model.where(conversation_id: conversation.id).count).to eq(0)
      expect(run_model.count).to eq(1)
      expect(run_model.first.registered).to eq(1)
    end

    it 'collapses two same-generation reconciliations (concurrent same-minute ticks) into one run' do
      # Two overlapping ticks in the same minute enqueue the SAME generation; the ledger + global
      # lock collapse them so the row is registered exactly once, never twice.
      agent = make_agent
      conversation, = crash_gap_orphan
      @online = [agent.id.to_s]
      gen = 'recovery-000000000000'
      cutoff = 1.minute.from_now

      perform_enqueued_jobs(only: process_inbox_job) do
        recon_job.perform_now(generation: gen, cutoff: cutoff)
        recon_job.perform_now(generation: gen, cutoff: cutoff)
      end

      expect(conversation.reload.assignee).to eq(agent)
      expect(run_model.where(generation: gen).count).to eq(1)
      expect(run_model.find_by(generation: gen).registered).to eq(1) # not 2
      expect(marker_model.where(conversation_id: conversation.id).count).to eq(0)
    end
  end

  describe 'lock contention is recoverable, never a silent strand' do
    it 'raises a retryable StandardError (LockContention) so ReconciliationJob.retry_on re-enqueues' do
      expect(reconciler::LockContention.ancestors).to include(StandardError)
    end
  end
end
