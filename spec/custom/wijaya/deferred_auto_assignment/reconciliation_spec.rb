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
  let(:registrar) { Wijaya::Batteries::DeferredAutoAssignment::Registrar }
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
      prior_assignee_id: prior.id, event: 'agent_deletion', event_at: event_at,
      deletion_key: "del-#{conversation.id}-#{prior.id}"
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

    it 'SUPERSEDES (never adopts) an orphan manually assigned before reconciliation; the claim is never overwritten' do
      spv = make_agent
      other = make_agent
      conversation, = orphan_with_provenance
      conversation.update!(assignee: spv) # a supervisor claimed it -> in-transaction supersession

      @online = [other.id.to_s]
      run = run_reconciliation

      expect(conversation.reload.assignee).to eq(spv)
      expect(marker_for(conversation)).to be_nil
      expect(run.registered).to eq(0)
      expect(run.scanned).to eq(0) # the superseded tombstone is excluded from the scan entirely
      expect(provenance_row(conversation).superseded_at).to be_present
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
                               prior_assignee_id: 999_999, event: 'agent_deletion', event_at: 1.hour.ago,
                               deletion_key: "del-cross-#{cross.id}")

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

  # Supervisor defect 1: a row must not be stamped reconciled until its registration disposition
  # has committed durably, so a Registrar failure can never permanently skip it on retry.
  describe 'retry safety when registration fails mid-run' do
    it 'leaves provenance unreconciled and the run incomplete, then resumes cleanly on retry without duplication' do
      make_agent
      conversation, = orphan_with_provenance
      @online = []

      calls = 0
      allow(registrar).to receive(:register_unassigned_from_provenance).and_wrap_original do |orig, *args, **kwargs|
        calls += 1
        raise StandardError, 'injected registration failure' if calls == 1

        orig.call(*args, **kwargs)
      end

      expect { reconciler.run(generation: 'gen-fail') }.to raise_error(StandardError, /injected/)

      failed_run = run_model.find_by(generation: 'gen-fail')
      expect(failed_run.completed?).to be(false)
      expect(failed_run.status).to eq('running')
      expect(failed_run.scanned).to eq(0)                    # counters rolled back with the batch
      expect(failed_run.failed).to eq(1)
      expect(provenance_row(conversation).reconciled_at).to be_nil
      expect(marker_for(conversation)).to be_nil             # no phantom marker from the failed attempt

      resumed = run_reconciliation(generation: 'gen-fail')   # a retry of the SAME generation
      expect(resumed.status).to eq('completed')
      expect(resumed.scanned).to eq(1)
      expect(resumed.registered).to eq(1)
      expect(resumed.retries).to eq(1)
      expect(provenance_row(conversation).reconciled_at).to be_present
      expect(marker_model.where(conversation_id: conversation.id).count).to eq(1)
    end
  end

  # Supervisor defect 2: counters must be cumulative + idempotent so a failure after some batches
  # completed, then a resume, still yields exact totals (nothing lost, nothing double-counted).
  describe 'cumulative counters across a multi-batch failure and resume' do
    it 'persists exact scanned/identified/registered/skipped/ambiguous totals' do
      stub_const("#{reconciler}::BATCH_SIZE", 1)
      make_agent
      c1, = orphan_with_provenance
      c2, = orphan_with_provenance
      c3, = orphan_with_provenance
      @online = []

      boom = true
      allow(registrar).to receive(:register_unassigned_from_provenance).and_wrap_original do |orig, account_id, ids, **kwargs|
        if boom && ids.include?(c2.id)
          boom = false
          raise StandardError, 'injected mid-run failure'
        end
        orig.call(account_id, ids, **kwargs)
      end

      expect { reconciler.run(generation: 'gen-multi') }.to raise_error(StandardError, /injected/)

      run = run_reconciliation(generation: 'gen-multi') # resume; drains queued ProcessInboxJobs too
      expect(run.status).to eq('completed')
      expect(run.scanned).to eq(3)
      expect(run.identified).to eq(3)
      expect(run.registered).to eq(3)
      expect(run.skipped).to eq(0)
      expect(run.ambiguous).to eq(0)
      expect(run.failed).to eq(1)
      expect(run.retries).to eq(1)
      [c1, c2, c3].each { |c| expect(provenance_row(c).reconciled_at).to be_present }
      expect(marker_model.where(conversation_id: [c1.id, c2.id, c3.id]).count).to eq(3)
    end
  end

  # Supervisor defect 3: "registered" must mean a marker was ACTUALLY adopted, not a pre-classification
  # prediction — a row claimed between classification and registration is skipped, never registered.
  describe 'registered reflects actual adoption, not classification' do
    it 'counts a candidate claimed between classification and registration as skipped, never registered' do
      system_agent = make_agent
      racer = make_agent
      conversation, = orphan_with_provenance

      allow(reconciler).to receive(:classify).and_wrap_original do |orig, row, cutoff|
        category = orig.call(row, cutoff)
        # Simulate a concurrent manual assignment that lands AFTER classification but BEFORE the
        # Registrar's re-check for this exact row.
        conversation.update!(assignee: racer) if category == :registered && row.conversation_id == conversation.id
        category
      end

      @online = [system_agent.id.to_s]
      run = run_reconciliation

      expect(conversation.reload.assignee).to eq(racer)   # the manual claim is never overwritten
      expect(run.identified).to eq(1)
      expect(run.registered).to eq(0)
      expect(run.skipped).to eq(1)
      expect(marker_for(conversation)).to be_nil
    end
  end

  # Supervisor defect 4: the run ledger must carry truthful, correlated assigned / no_eligible_agent /
  # dropped counters (latest unique disposition per conversation), not just registration counts.
  describe 'async assignment-outcome observability (correlated to the generation)' do
    it 'records identified + assigned when the orphan is reassigned by the pipeline' do
      agent = make_agent
      conversation, = orphan_with_provenance

      @online = [agent.id.to_s]
      run = run_reconciliation

      expect(conversation.reload.assignee).to eq(agent)
      expect(run.reload.identified).to eq(1)
      expect(run.registered).to eq(1)
      expect(run.assigned).to eq(1)
      expect(run.no_eligible_agent).to eq(0)
      expect(run.dropped).to eq(0)
    end

    it 'counts no_eligible_agent once across repeated no-agent passes, then transitions it to assigned' do
      agent = make_agent
      conversation, = orphan_with_provenance

      @online = []
      run = run_reconciliation
      expect(run.reload.registered).to eq(1)
      expect(run.no_eligible_agent).to eq(1)

      # A second no-agent trigger must not double-count the same waiting conversation.
      perform_enqueued_jobs(only: process_inbox_job) { process_inbox_job.enqueue_for_inbox(inbox.id) }
      expect(run.reload.no_eligible_agent).to eq(1)

      # An agent comes online: the waiting count transitions down as it becomes assigned.
      @online = [agent.id.to_s]
      perform_enqueued_jobs(only: process_inbox_job) { process_inbox_job.enqueue_for_inbox(inbox.id) }
      expect(conversation.reload.assignee).to eq(agent)
      expect(run.reload.no_eligible_agent).to eq(0)
      expect(run.assigned).to eq(1)
      expect(run.registered).to eq(1)
    end

    it 'transitions a waiting orphan to dropped when it is manually assigned between passes' do
      spv = make_agent
      conversation, = orphan_with_provenance

      @online = []
      run = run_reconciliation
      expect(run.reload.no_eligible_agent).to eq(1)

      conversation.update!(assignee: spv) # manual claim -> lifecycle cleanup drops the marker

      expect(run.reload.no_eligible_agent).to eq(0)
      expect(run.dropped).to eq(1)
      expect(run.assigned).to eq(0)
      expect(marker_for(conversation)).to be_nil
    end
  end

  # Supervisor defect 5: two jobs for the same generation must not double-process rows or finalize
  # inconsistently.
  describe 'concurrent / duplicate job safety' do
    it 'claims each batch with FOR UPDATE SKIP LOCKED so a concurrent job locks disjoint rows' do
      expect(reconciler.batch_scope(1.minute.from_now).to_sql).to include('FOR UPDATE SKIP LOCKED')
    end

    it 'a duplicate invocation for the same generation neither re-registers nor double-counts' do
      make_agent
      conversation, = orphan_with_provenance

      @online = []
      first = run_reconciliation(generation: 'gen-dup')
      expect(first.registered).to eq(1)
      expect(marker_model.where(conversation_id: conversation.id).count).to eq(1)

      second = run_reconciliation(generation: 'gen-dup')
      expect(second.scanned).to eq(1)       # unchanged
      expect(second.registered).to eq(1)    # not 2
      expect(marker_model.where(conversation_id: conversation.id).count).to eq(1)
    end
  end

  # Supervisor defect A: the coalesced enqueue happens AFTER the scan commits. If it raised (or the
  # process died) the reconciled+marked row would previously be finalized with no job, stranding the
  # marker. The reconciliation-stamped markers are now a durable outbox: a retry re-dispatches every
  # still-present generation marker, so no marker is ever stranded and nothing is double-processed.
  describe 'durable dispatch: an enqueue failure after the scan commits never strands a marker' do
    it 'leaves provenance reconciled + marker adopted but the run incomplete, then a retry dispatches and assigns' do
      agent = make_agent
      conversation, = orphan_with_provenance
      @online = [agent.id.to_s]

      calls = 0
      allow(process_inbox_job).to receive(:enqueue_for_inbox).and_wrap_original do |orig, *args|
        calls += 1
        raise StandardError, 'injected enqueue failure' if calls == 1

        orig.call(*args)
      end

      expect { reconciler.run(generation: 'gen-dispatch') }.to raise_error(StandardError, /injected enqueue/)

      failed = run_model.find_by(generation: 'gen-dispatch')
      expect(failed.completed?).to be(false)
      expect(failed.status).to eq('running')
      expect(failed.registered).to eq(1)                            # the scan committed
      expect(failed.failed).to eq(1)
      expect(provenance_row(conversation).reconciled_at).to be_present
      expect(marker_for(conversation)).to be_present                # durable outbox entry survives

      resumed = run_reconciliation(generation: 'gen-dispatch')      # retry re-dispatches from markers
      expect(resumed.completed?).to be(true)
      expect(resumed.scanned).to eq(1)
      expect(resumed.registered).to eq(1)                           # not double-counted
      expect(resumed.retries).to eq(1)
      expect(conversation.reload.assignee).to eq(agent)
      expect(marker_for(conversation)).to be_nil                    # assigned -> marker resolved
      expect(run_model.where(generation: 'gen-dispatch').count).to eq(1) # no duplicate run
    end

    it 'partial multi-inbox enqueue failure: a retry re-dispatches the remaining generation markers and completes' do
      agent = make_agent
      inbox2 = create(:inbox, account: account, enable_auto_assignment: true)
      agent2 = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: inbox2, user: agent2)
      contact_inbox2 = create(:contact_inbox, contact: contact, inbox: inbox2)

      c1, = orphan_with_provenance # in the shared inbox
      prior2 = create(:user, account: account, role: :agent)
      c2 = Conversation.create!(account: account, inbox: inbox2, contact: contact,
                                contact_inbox: contact_inbox2, assignee: prior2)
      c2.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations
      marker_model.where(conversation_id: c2.id).delete_all
      Redis::Alfred.delete(format(process_inbox_job::IN_FLIGHT_KEY, inbox_id: inbox2.id))
      Redis::Alfred.delete(format(process_inbox_job::RERUN_KEY, inbox_id: inbox2.id))
      provenance_model.create!(account: account, conversation: c2, inbox: inbox2,
                               prior_assignee_id: prior2.id, event: 'agent_deletion', event_at: 1.hour.ago,
                               deletion_key: "del-#{c2.id}-#{prior2.id}")
      AccountUser.where(account_id: account.id, user_id: prior2.id).delete_all

      @online = [agent.id.to_s, agent2.id.to_s]

      fail_inbox2 = true
      allow(process_inbox_job).to receive(:enqueue_for_inbox).and_wrap_original do |orig, inbox_id|
        raise StandardError, 'injected enqueue failure' if fail_inbox2 && inbox_id == inbox2.id

        orig.call(inbox_id)
      end

      expect { reconciler.run(generation: 'gen-multi-dispatch') }.to raise_error(StandardError, /injected enqueue/)

      # Both markers durably adopted + both provenance reconciled despite the partial dispatch failure.
      expect(marker_model.where(conversation_id: [c1.id, c2.id]).count).to eq(2)
      expect(provenance_row(c1).reconciled_at).to be_present
      expect(provenance_row(c2).reconciled_at).to be_present
      partial = run_model.find_by(generation: 'gen-multi-dispatch')
      expect(partial.completed?).to be(false)
      expect(partial.registered).to eq(2)

      # Recover: retry re-dispatches ALL still-present generation markers and completes.
      fail_inbox2 = false
      [inbox.id, inbox2.id].each do |iid|
        Redis::Alfred.delete(format(process_inbox_job::IN_FLIGHT_KEY, inbox_id: iid))
        Redis::Alfred.delete(format(process_inbox_job::RERUN_KEY, inbox_id: iid))
      end
      resumed = run_reconciliation(generation: 'gen-multi-dispatch')
      expect(resumed.completed?).to be(true)
      expect(resumed.registered).to eq(2) # not doubled
      expect(c1.reload.assignee).to eq(agent)
      expect(c2.reload.assignee).to eq(agent2)
    end
  end

  # Supervisor defect B (corrected): FOR UPDATE SKIP LOCKED alone does not stop a second job from
  # observing no unlocked rows (while the owner holds the last batch), completing the run, and then
  # the owner rolling back — permanently abandoning rows. The whole run is now serialized under a
  # single GLOBAL advisory lock (not per-generation), so the one-time migration run and every
  # recurring drainer run are strictly serialized. A job that cannot take the lock RAISES
  # (LockContention) rather than returning a successful no-op: it never scans, dispatches, or
  # finalizes while another run owns the lock, AND it never strands its own run row 'running' —
  # ReconciliationJob's retry_on re-enqueues it so its generation is eventually processed.
  describe 'single-run serialization (a contending job raises for retry, never completes/strands a run)' do
    it 'raises LockContention without scanning/dispatching/finalizing, and a retry completes it' do
      make_agent
      conversation, = orphan_with_provenance
      @online = []

      # First call: another run owns the global lock (acquire fails). Second call (retry): it is free.
      allow(reconciler).to receive(:acquire_global_lock).and_return(false, true)
      allow(reconciler).to receive(:release_global_lock)

      expect { reconciler.run(generation: 'gen-lock') }.to raise_error(reconciler::LockContention)

      blocked = run_model.find_by(generation: 'gen-lock')
      expect(blocked.completed?).to be(false)
      expect(blocked.status).to eq('running')
      expect(blocked.scanned).to eq(0)
      expect(blocked.registered).to eq(0)
      expect(provenance_row(conversation).reconciled_at).to be_nil
      expect(marker_for(conversation)).to be_nil

      # The lock frees; the retry_on-driven re-enqueue serializes and finishes — no stranded run.
      resumed = run_reconciliation(generation: 'gen-lock')
      expect(resumed.completed?).to be(true)
      expect(resumed.scanned).to eq(1)
      expect(resumed.registered).to eq(1)
      expect(resumed.retries).to eq(1)
      expect(provenance_row(conversation).reconciled_at).to be_present
      expect(marker_model.where(conversation_id: conversation.id).count).to eq(1)
    end
  end

  # Supervisor defect C: a marker's outcome/removal transition and the run counter transition must be
  # atomic, or a crash between them permanently diverges them (undercount that never self-heals).
  describe 'outcome counter atomicity (marker state and run counters never diverge)' do
    let(:plain_conversation) do
      Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox).tap do |c|
        marker_model.where(conversation_id: c.id).delete_all
      end
    end

    it 'record_waiting rolls the marker transition back when the ledger update raises' do
      run = run_model.create!(generation: 'gen-atomic-w', status: 'running', started_at: Time.current, cutoff_at: Time.current)
      marker = marker_model.create!(account: account, inbox: inbox, conversation: plain_conversation,
                                    reconciliation_generation: 'gen-atomic-w')
      allow(run_model).to receive(:record_outcome).and_raise(StandardError, 'ledger boom')

      expect { marker_model.record_waiting(plain_conversation.id) }.to raise_error(StandardError, /ledger boom/)

      expect(marker.reload.reconciliation_outcome).to be_nil # transition rolled back with the failed ledger update
      expect(run.reload.no_eligible_agent).to eq(0)          # counter untouched — no divergence
    end

    it 'resolve_and_record keeps the marker when the ledger update raises' do
      run = run_model.create!(generation: 'gen-atomic-r', status: 'running', started_at: Time.current,
                              cutoff_at: Time.current, no_eligible_agent: 1)
      marker_model.create!(account: account, inbox: inbox, conversation: plain_conversation,
                           reconciliation_generation: 'gen-atomic-r', reconciliation_outcome: run_model::NO_ELIGIBLE_AGENT)
      allow(run_model).to receive(:record_outcome).and_raise(StandardError, 'ledger boom')

      expect do
        marker_model.resolve_and_record(plain_conversation.id, run_model::ASSIGNED)
      end.to raise_error(StandardError, /ledger boom/)

      expect(marker_model.where(conversation_id: plain_conversation.id).count).to eq(1) # delete rolled back
      expect(run.reload.no_eligible_agent).to eq(1)                                     # counters unchanged
      expect(run.assigned).to eq(0)
    end
  end

  # Supervisor defect D: resolve_and_record must read the marker's generation/previous disposition
  # INSIDE its transaction, under a SELECT ... FOR UPDATE lock — never from a stale pre-transaction
  # read. Otherwise a no-agent pass that transitions the marker nil -> NO_ELIGIBLE_AGENT (bumping that
  # counter) in the window between the stale read and the delete would leave resolve passing the stale
  # previous=nil to record_outcome(ASSIGNED), so BOTH no_eligible_agent AND assigned end at 1 for one
  # conversation — two live buckets, violating latest-unique-disposition semantics.
  #
  # This is a deterministic interleaving: the suite runs each example inside one transactional-fixture
  # connection, so we model the race by committing the competing record_waiting exactly in that window.
  # Wrapping Marker.transaction fires the racing pass AFTER resolve_and_record is entered but BEFORE its
  # own transaction body runs (where the fixed code takes the lock and reads previous). The fixed code
  # then re-reads previous=NO_ELIGIBLE_AGENT under the lock and nets it out; a regression that captured
  # previous before the transaction would instead double-bucket, failing this test.
  describe 'concurrency: a no_eligible_agent transition racing resolve-to-assigned cannot double-count' do
    let(:plain_conversation) do
      Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox).tap do |c|
        marker_model.where(conversation_id: c.id).delete_all
      end
    end

    it 'leaves assigned=1, no_eligible_agent=0, and the marker absent (never both buckets)' do
      run = run_model.create!(generation: 'gen-race', status: 'running', started_at: Time.current, cutoff_at: Time.current)
      marker_model.create!(account: account, inbox: inbox, conversation: plain_conversation,
                           reconciliation_generation: 'gen-race')

      injected = false
      allow(marker_model).to receive(:transaction).and_wrap_original do |orig, *args, &block|
        unless injected
          injected = true
          # The racing no-agent pass commits its nil -> no_eligible_agent transition (and bumps that
          # counter) in the window after resolve_and_record is entered but before it locks the marker.
          marker_model.record_waiting(plain_conversation.id)
        end
        orig.call(*args, &block)
      end

      marker_model.resolve_and_record(plain_conversation.id, run_model::ASSIGNED)

      expect(marker_model.where(conversation_id: plain_conversation.id).count).to eq(0) # marker absent
      expect(run.reload.assigned).to eq(1)
      expect(run.no_eligible_agent).to eq(0) # transitioned down, not left alongside assigned
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

  # Blocker C: a pending tombstone must NEVER be adopted after an intervening intentional transition
  # (manual/human/bot assignment, team/inbox routing, or close/reopen) — even once the conversation is
  # open + assignee-nil again. The in-transaction supersession seam stamps superseded_at the instant
  # such a transition commits, so the reconciler never scans/adopts it. The deletion-caused
  # unassignment itself (update_all, callback-free) never supersedes its own tombstone.
  describe 'causal continuity (superseded tombstones are never adopted)' do
    def expect_not_adopted(conversation, run)
      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_nil
      expect(run.registered).to eq(0)
      expect(run.scanned).to eq(0)
      expect(provenance_row(conversation).superseded_at).to be_present
    end

    # These use no online agent, so the ONLY thing that could adopt the conversation is the
    # reconciliation — proving supersession (not merely a lack of online agents) blocks it.
    it 'assign -> unassign: never re-adopted' do
      agent = make_agent
      conversation, = orphan_with_provenance
      conversation.update!(assignee: agent)   # intervening human assignment breaks the chain
      conversation.update!(assignee_id: nil)  # then unassigned again -> open + nil, but superseded

      expect_not_adopted(conversation, run_reconciliation)
    end

    it 'close -> reopen: never re-adopted' do
      make_agent
      conversation, = orphan_with_provenance
      conversation.update!(status: :resolved) # intentional state transition
      conversation.update!(status: :open)     # reopened -> open + nil, but superseded

      expect_not_adopted(conversation, run_reconciliation)
    end

    it 'bot ownership -> unassigned: never re-adopted' do
      make_agent
      conversation, = orphan_with_provenance
      agent_bot = create(:agent_bot, account: account)
      conversation.update!(assignee_agent_bot_id: agent_bot.id) # bot took over
      conversation.update!(assignee_agent_bot_id: nil)          # bot removed -> open + nil, superseded

      expect_not_adopted(conversation, run_reconciliation)
    end

    it 'team-routing change: never adopted even though the conversation stays deferrable' do
      team = create(:team, account: account, allow_auto_assign: true)
      make_agent(team: team)
      conversation, = orphan_with_provenance
      conversation.update!(team: team) # intentional routing change breaks the chain

      expect_not_adopted(conversation, run_reconciliation)
    end

    # Inbox routing (inbox A -> inbox B) is a manual routing transition that supersedes pending
    # provenance exactly like a team change. This makes an eligible online agent available in inbox
    # B, so the ONLY thing that can keep the conversation from being adopted is the supersession —
    # proving saved_change_to_inbox_id? is honoured and the tombstone is never re-adopted afterwards.
    it 'inbox-routing change (inbox A -> inbox B): superseded and never adopted' do
      inbox_b = create(:inbox, account: account, enable_auto_assignment: true)
      agent_b = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: inbox_b, user: agent_b)
      conversation, = orphan_with_provenance
      conversation.update!(inbox: inbox_b) # intentional inbox routing change breaks the chain

      @online = [agent_b.id.to_s] # an eligible online agent exists in inbox B
      expect_not_adopted(conversation, run_reconciliation)
    end

    it 'a genuine crash-gap orphan (no intervening transition) is STILL adopted' do
      agent = make_agent
      conversation, = orphan_with_provenance # cleared via update_all/update_column, no callback fired

      @online = [agent.id.to_s]
      run = run_reconciliation

      expect(conversation.reload.assignee).to eq(agent)
      expect(run.registered).to eq(1)
      expect(provenance_row(conversation).superseded_at).to be_nil
    end
  end

  # Blocker D: a reconciliation-owned marker removed by has_one dependent: :destroy (conversation
  # deletion) bypasses resolve_and_record. The Marker after_destroy must transactionally record a
  # terminal DROPPED and reverse the prior latest disposition exactly once, without double-counting,
  # and be a no-op for an ordinary (generation-less) marker.
  describe 'terminal counter accounting on conversation/marker deletion' do
    it 'reverses no_eligible_agent and records DROPPED exactly once when the conversation is destroyed' do
      make_agent
      conversation, = orphan_with_provenance
      @online = []
      run = run_reconciliation
      expect(run.reload.no_eligible_agent).to eq(1)
      expect(marker_for(conversation)).to be_present

      conversation.destroy! # dependent: :destroy removes the marker via marker.destroy (not delete_all)

      expect(marker_for(conversation)).to be_nil
      expect(run.reload.no_eligible_agent).to eq(0) # prior disposition reversed
      expect(run.dropped).to eq(1)                  # terminal DROPPED recorded exactly once
      expect(run.assigned).to eq(0)
    end

    it 'records DROPPED for a registered marker that never got an async disposition yet' do
      conversation, = orphan_with_provenance
      run = run_model.create!(generation: 'gen-fresh-drop', status: 'running', started_at: Time.current,
                              cutoff_at: Time.current, registered: 1)
      registrar.register_unassigned_from_provenance(account.id, [conversation.id], generation: 'gen-fresh-drop')
      expect(marker_for(conversation).reconciliation_outcome).to be_nil

      conversation.destroy!

      expect(run.reload.dropped).to eq(1)
      expect(run.no_eligible_agent).to eq(0)
    end

    it 'does not touch any run ledger when an ordinary (generation-less) marker’s conversation is destroyed' do
      run = run_model.create!(generation: 'gen-ordinary', status: 'running', started_at: Time.current,
                              cutoff_at: Time.current, no_eligible_agent: 1)
      plain = Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      marker_model.find_or_create_by!(conversation_id: plain.id) do |m|
        m.account_id = account.id
        m.inbox_id = inbox.id
      end
      expect(marker_for(plain).reconciliation_generation).to be_nil

      plain.destroy!

      expect(marker_for(plain)).to be_nil
      expect(run.reload.no_eligible_agent).to eq(1) # untouched
      expect(run.dropped).to eq(0)
    end
  end
end
