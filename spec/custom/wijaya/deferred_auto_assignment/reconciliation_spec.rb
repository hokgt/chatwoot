# frozen_string_literal: true

require 'rails_helper'

# Automatic, one-time historical reconciliation for the deferred auto-assignment battery. It scans
# ONLY durable provenance tombstones (never all unassigned conversations), fails closed on any
# uncertainty, and adopts a proven deleted-agent orphan into the EXACT existing live pipeline
# (Registrar.register_unassigned_from_provenance -> Marker -> ProcessInboxJob -> InboxProcessor ->
# native AgentAssignmentService -> conversation.update! -> existing ERP owner-sync callback). It
# never writes assignee_id directly and never introduces a second assignment engine. Conversations
# lacking a provenance row (the pre-feature backlog) are never guessed from free-text activity.
RSpec.describe 'Deferred auto-assignment historical reconciliation', type: :model do
  let(:provenance_model) { Wijaya::Batteries::DeferredAutoAssignment::DeletionProvenance }
  let(:run_model) { Wijaya::Batteries::DeferredAutoAssignment::ReconciliationRun }
  let(:marker_model) { Wijaya::Batteries::DeferredAutoAssignment::Marker }
  let(:reconciler) { Wijaya::Batteries::DeferredAutoAssignment::Reconciler }
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
    @online = []
    allow(OnlineStatusTracker).to receive(:get_available_users) { @online.index_with { 'online' } }
    allow(AutoAssignment::InboxRoundRobinService).to receive(:new).and_return(round_robin_picker)
    allow(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox)
    # ERP owner-sync is an EXISTING battery callback; stub only its enqueue (never a real push).
    allow(erp_owner_sync_job).to receive(:perform_later)
  end

  def make_agent(inbox_member: true, team: nil)
    user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: user) if inbox_member
    create(:team_member, team: team, user: user) if team
    user
  end

  def marker_for(conversation)
    marker_model.find_by(conversation_id: conversation.id)
  end

  # A conversation that lost its human assignee to an agent deletion, WITH a durable provenance
  # tombstone but NO marker and still unassigned — i.e. the crash-gap the reconciliation exists
  # for. The prior agent's account membership is removed so deletion is structurally confirmed.
  def orphan_with_provenance(params = {}, event_at: 1.hour.ago, confirm_deleted: true)
    @online = []
    prior = create(:user, account: account, role: :agent)
    conversation = Conversation.create!(
      { account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: prior }.merge(params)
    )
    conversation.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations
    reset_clean_pre_feature_state(conversation)
    provenance_model.create!(
      account: account, conversation: conversation, inbox: inbox,
      prior_assignee_id: prior.id, event: 'agent_deletion', event_at: event_at
    )
    AccountUser.where(account_id: account.id, user_id: prior.id).delete_all if confirm_deleted
    [conversation, prior]
  end

  # Guarantee a clean pre-feature row: no marker and no lingering per-inbox in-flight/rerun key
  # that would coalesce away the reconciliation's enqueue.
  def reset_clean_pre_feature_state(conversation)
    marker_model.where(conversation_id: conversation.id).delete_all
    Redis::Alfred.delete(format(process_inbox_job::IN_FLIGHT_KEY, inbox_id: conversation.inbox_id))
    Redis::Alfred.delete(format(process_inbox_job::RERUN_KEY, inbox_id: conversation.inbox_id))
  end

  def link_erp_lead(conversation)
    Wijaya::ErpLeadDraft.create!(
      account: account, conversation: conversation, fields: {}, erp_lead_id: 'LEAD-0001', sync_status: 'draft'
    )
  end

  def provenance_row(conversation)
    provenance_model.find_by(conversation_id: conversation.id)
  end

  # Drive the real pipeline: reconcile, then let the queued ProcessInboxJob assign.
  def run_reconciliation(generation: 'gen-test')
    perform_enqueued_jobs(only: process_inbox_job) do
      reconciler.run(generation: generation)
    end
  end

  describe 'a provenance-backed deleted-agent orphan is adopted through the existing pipeline' do
    it 'registers and reassigns it to an eligible online agent, then marks it reconciled' do
      agent = make_agent # live, online agent to receive the reassignment
      conversation, = orphan_with_provenance

      @online = [agent.id.to_s]
      run = run_reconciliation

      expect(conversation.reload.assignee).to eq(agent)
      expect(marker_for(conversation)).to be_nil
      expect(provenance_row(conversation).reconciled_at).to be_present
      expect(run.registered).to eq(1)
    end

    it 'invokes the existing ERP owner-sync enqueue (no direct ERP call) when a lead is linked' do
      agent = make_agent
      conversation, = orphan_with_provenance
      link_erp_lead(conversation)

      @online = [agent.id.to_s]
      run_reconciliation

      expect(conversation.reload.assignee).to eq(agent)
      expect(erp_owner_sync_job).to have_received(:perform_later).with(conversation.id, agent.id)
    end

    it 'leaves it unassigned WITH the marker retained when no agent is available' do
      make_agent # an offline inbox member exists
      conversation, = orphan_with_provenance

      @online = []
      run = run_reconciliation

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_present
      expect(run.registered).to eq(1)
    end
  end

  describe 'fail-closed protections (never registered)' do
    it 'ignores an intentionally-unassigned conversation with NO provenance row' do
      make_agent
      intentional = Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      marker_model.where(conversation_id: intentional.id).delete_all

      @online = [make_agent.id.to_s]
      run = run_reconciliation

      expect(intentional.reload.assignee_id).to be_nil
      expect(marker_for(intentional)).to be_nil
      expect(run.scanned).to eq(0)
    end

    it 'ignores a conversation whose free-text activity says "Assigned to Rizal Agent" but has NO provenance' do
      make_agent
      conversation = Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      conversation.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations
      marker_model.where(conversation_id: conversation.id).delete_all
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :activity, content: 'Assigned to Rizal Agent by the System')

      @online = [make_agent.id.to_s]
      run = run_reconciliation

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_nil
      expect(run.scanned).to eq(0)
    end

    it 'is AMBIGUOUS when the prior assignee is still an account member (not actually deleted)' do
      agent = make_agent
      conversation, = orphan_with_provenance(confirm_deleted: false) # prior membership left intact

      @online = [agent.id.to_s]
      run = run_reconciliation

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_nil
      expect(run.ambiguous).to eq(1)
      expect(run.registered).to eq(0)
      expect(provenance_row(conversation).reconciled_at).to be_present
    end

    it 'ignores a team-routed conversation that never had a deleted human assignee (no provenance)' do
      team = create(:team, account: account, allow_auto_assign: true)
      make_agent(team: team)
      routed = Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, team: team)
      routed.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations
      marker_model.where(conversation_id: routed.id).delete_all

      run = run_reconciliation

      expect(routed.reload.assignee_id).to be_nil
      expect(marker_for(routed)).to be_nil
      expect(run.scanned).to eq(0)
    end

    it 'SKIPS an orphan that was manually assigned before reconciliation (never overwritten)' do
      spv = make_agent
      other = make_agent
      conversation, = orphan_with_provenance
      conversation.update!(assignee: spv) # a supervisor claimed it first

      @online = [other.id.to_s]
      run = run_reconciliation

      expect(conversation.reload.assignee).to eq(spv)
      expect(marker_for(conversation)).to be_nil
      expect(run.registered).to eq(0)
      expect(run.skipped).to eq(1)
    end

    it 'SKIPS a resolved (non-open) orphan' do
      make_agent
      conversation, = orphan_with_provenance
      conversation.update_columns(status: Conversation.statuses[:resolved]) # rubocop:disable Rails/SkipsModelValidations

      @online = [make_agent.id.to_s]
      run = run_reconciliation

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_nil
      expect(run.skipped).to eq(1)
    end

    it 'SKIPS an agent-bot–owned orphan' do
      make_agent
      conversation, = orphan_with_provenance
      agent_bot = create(:agent_bot, account: account)
      conversation.update_column(:assignee_agent_bot_id, agent_bot.id) # rubocop:disable Rails/SkipsModelValidations

      @online = [make_agent.id.to_s]
      run = run_reconciliation

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_nil
      expect(run.skipped).to eq(1)
    end

    it 'is AMBIGUOUS for a cross-account provenance row (conversation account ≠ provenance account)' do
      other_account = create(:account)
      other_inbox = create(:inbox, account: other_account, enable_auto_assignment: true)
      other_contact = create(:contact, account: other_account)
      cross = create(:conversation, account: other_account, inbox: other_inbox, contact: other_contact,
                                    contact_inbox: create(:contact_inbox, contact: other_contact, inbox: other_inbox))
      cross.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations
      marker_model.where(conversation_id: cross.id).delete_all # drop any creation-time marker
      # Provenance deliberately mislabels the account as ours.
      provenance_model.create!(account: account, conversation: cross, inbox: other_inbox,
                               prior_assignee_id: 999_999, event: 'agent_deletion', event_at: 1.hour.ago)

      run = run_reconciliation

      expect(cross.reload.assignee_id).to be_nil
      expect(marker_model.where(conversation_id: cross.id).count).to eq(0)
      expect(run.ambiguous).to eq(1)
      expect(run.registered).to eq(0)
    end
  end

  describe 'idempotency / one-time semantics' do
    it 'SKIPS an orphan that already carries a marker (live pipeline owns it) without double-marking' do
      make_agent
      conversation, = orphan_with_provenance
      marker_model.find_or_create_by!(conversation_id: conversation.id) do |m|
        m.account_id = account.id
        m.inbox_id = inbox.id
      end

      @online = []
      run = run_reconciliation

      expect(marker_model.where(conversation_id: conversation.id).count).to eq(1)
      expect(run.skipped).to eq(1)
      expect(run.registered).to eq(0)
    end

    it 'records completion + cutoff and never re-scans on a second run of the same generation' do
      make_agent
      orphan_with_provenance

      @online = []
      first = run_reconciliation(generation: 'gen-once')
      expect(first.status).to eq('completed')
      expect(first.cutoff_at).to be_present
      expect(first.finished_at).to be_present
      expect(first.scanned).to eq(1)

      # A second run of the SAME generation is a completed no-op (no rescan).
      expect(reconciler).not_to receive(:scope)
      second = reconciler.run(generation: 'gen-once')
      expect(second.id).to eq(first.id)
      expect(second.scanned).to eq(1) # unchanged
    end

    it 'does not duplicate a marker or assignment across a retried run (same generation resumes)' do
      make_agent
      conversation, = orphan_with_provenance

      @online = []
      run_reconciliation(generation: 'gen-retry')
      expect(marker_model.where(conversation_id: conversation.id).count).to eq(1)

      # Re-running the same generation is a no-op; the marker is not duplicated.
      run_reconciliation(generation: 'gen-retry')
      expect(marker_model.where(conversation_id: conversation.id).count).to eq(1)
      expect(conversation.reload.assignee_id).to be_nil
    end

    it 'reconciles multiple provenance rows in one bounded run (all stamped reconciled)' do
      make_agent
      c1, = orphan_with_provenance
      c2, = orphan_with_provenance

      @online = []
      run = run_reconciliation(generation: 'gen-batch')

      expect(run.scanned).to eq(2)
      expect(provenance_row(c1).reconciled_at).to be_present
      expect(provenance_row(c2).reconciled_at).to be_present
    end
  end

  describe 'ReconciliationJob delegates to the reconciler' do
    it 'runs the reconciler for the given generation' do
      make_agent
      conversation, = orphan_with_provenance

      @online = [make_agent.id.to_s]
      perform_enqueued_jobs(only: process_inbox_job) do
        recon_job.perform_now(generation: 'job-gen')
      end

      expect(run_model.find_by(generation: 'job-gen')).to be_present
      expect(conversation.reload.assignee_id).to be_present
    end
  end
end
