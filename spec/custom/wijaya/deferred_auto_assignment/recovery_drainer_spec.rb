# frozen_string_literal: true

require 'rails_helper'

# Recovery drainer + run-intent COORDINATOR for the deferred auto-assignment battery. It is the
# durable-outbox / crash-gap FALLBACK (NOT the primary future deletion mechanism, which stays
# Agents::DestroyJob -> Registrar). It is itself ONE hourly scheduled cron occurrence, and each tick
# selects AT MOST ONE persisted run intent and runs the Reconciler INLINE (a direct Reconciler.run
# under the Reconciler's global advisory lock) — it NEVER hands off to a second Redis queue via
# ReconciliationJob.perform_later/perform_now. It scans ONLY unreconciled DeletionProvenance
# tombstones older than a safety age, never all Unassigned conversations, never writes assignee_id
# directly, and no-ops (no run, no reconciliation) when nothing is due. Expected failures (global-lock
# contention, a transient reconciliation error) are logged and swallowed so no independent, unbounded
# retry tree forms; the next hourly tick is the bounded retry.
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

  # A durable, still-waiting Marker row on its OWN inbox (distinct inbox_id), with no lingering
  # in-flight/rerun key — the durable-outbox unit the marker drain redispatches. No provenance and no
  # reconciliation run is involved: the drain acts on the marker table alone.
  def waiting_marker_on_new_inbox
    ibx = create(:inbox, account: account, enable_auto_assignment: true)
    ci = create(:contact_inbox, contact: contact, inbox: ibx)
    conversation = Conversation.create!(account: account, inbox: ibx, contact: contact, contact_inbox: ci)
    conversation.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations
    marker_model.where(conversation_id: conversation.id).delete_all # drop any creation-time marker
    marker_model.create!(account: account, inbox: ibx, conversation: conversation)
    Redis::Alfred.delete(format(process_inbox_job::IN_FLIGHT_KEY, inbox_id: ibx.id))
    Redis::Alfred.delete(format(process_inbox_job::RERUN_KEY, inbox_id: ibx.id))
    ibx
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
      prior_assignee_id: prior.id, event: 'agent_deletion', event_at: event_at,
      deletion_key: "del-#{conversation.id}-#{prior.id}"
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

  # Run the drainer (which reconciles INLINE) and cascade the per-inbox assignment it enqueues. Only
  # ProcessInboxJob is enqueued now — the drainer no longer enqueues a ReconciliationJob at all.
  def run_drainer
    perform_enqueued_jobs(only: [process_inbox_job]) { drainer.perform_now }
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

  describe 'it reconciles INLINE, never enqueuing a second ReconciliationJob' do
    it 'calls Reconciler.run directly and never enqueues ReconciliationJob' do
      agent = make_agent
      conversation, = crash_gap_orphan
      @online = [agent.id.to_s]
      expect(recon_job).not_to receive(:perform_later)
      expect(recon_job).not_to receive(:perform_now)
      expect(reconciler).to receive(:run).once.and_call_original

      run_drainer

      expect(conversation.reload.assignee).to eq(agent)
      expect(run_model.count).to eq(1)
    end
  end

  describe 'self-gating: it never runs when nothing is due' do
    it 'does nothing — no run, no reconciliation — when there is no provenance and no incomplete run' do
      make_agent
      expect(provenance_model.count).to eq(0)
      expect(reconciler).not_to receive(:run)
      expect(recon_job).not_to receive(:perform_later)

      expect { drainer.perform_now }.not_to change(run_model, :count)
    end

    it 'does not drain provenance younger than the safety age (never races the live bridge)' do
      make_agent
      crash_gap_orphan(event_at: 1.minute.ago) # inside the SAFETY_AGE window
      expect(reconciler).not_to receive(:run)
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

      expect(reconciler).not_to receive(:run)
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

    it 'collapses two same-generation inline reconciliations (same-minute ticks) into one run' do
      # Two overlapping ticks in the same minute find-or-create the SAME generation; the ledger's
      # unique generation + the global advisory lock collapse them so the row is registered exactly
      # once, never twice.
      agent = make_agent
      conversation, = crash_gap_orphan
      @online = [agent.id.to_s]
      gen = 'recovery-000000000000'
      cutoff = 1.minute.from_now

      perform_enqueued_jobs(only: process_inbox_job) do
        reconciler.run(generation: gen, cutoff: cutoff)
        reconciler.run(generation: gen, cutoff: cutoff)
      end

      expect(conversation.reload.assignee).to eq(agent)
      expect(run_model.where(generation: gen).count).to eq(1)
      expect(run_model.find_by(generation: gen).registered).to eq(1) # not 2
      expect(marker_model.where(conversation_id: conversation.id).count).to eq(0)
    end

    it 'a second same-minute tick does not create a duplicate recovery run row' do
      # With a stalled reconciler the first tick opens ONE fresh recovery generation and leaves it
      # running; the second tick in the same minute must resume that SAME run, never open a duplicate.
      make_agent
      crash_gap_orphan
      allow(reconciler).to receive(:run) # stall: leave whatever run is opened incomplete

      travel_to(Time.zone.local(2026, 9, 12, 10, 15, 30)) do
        drainer.perform_now
        drainer.perform_now
      end

      expect(run_model.where("generation LIKE 'recovery-%'").count).to eq(1)
    end
  end

  describe 'inline failures never spawn an independent retry tree; the next tick is the bounded retry' do
    it 'is a retryable StandardError so it can be rescued/retried, never a silent strand' do
      expect(reconciler::LockContention.ancestors).to include(StandardError)
    end

    it 'swallows LockContention (no raise, no ReconciliationJob enqueue); the run is left for the next tick' do
      run = run_model.create!(generation: 'gen-locked', status: 'running', started_at: Time.current, cutoff_at: Time.current)
      allow(reconciler).to receive(:run).and_raise(reconciler::LockContention.new('lock busy'))
      expect(recon_job).not_to receive(:perform_later)

      expect { drainer.perform_now }.not_to raise_error
      expect(run.reload.status).to eq('running')
    end

    it 'swallows a transient reconciliation failure; a later tick resumes the SAME run and completes it' do
      run = run_model.create!(generation: 'gen-intent-fail', status: 'running', started_at: nil, cutoff_at: Time.current)

      calls = 0
      allow(reconciler).to receive(:run).and_wrap_original do |orig, **kwargs|
        calls += 1
        raise StandardError, 'transient boom' if calls == 1

        orig.call(**kwargs)
      end

      # First tick: the inline reconciliation fails. It must NOT re-raise (which would let ActiveJob's
      # Sidekiq default retry spin an unbounded retry tree) and the durable intent must stay running.
      expect { drainer.perform_now }.not_to raise_error
      expect(run.reload.status).to eq('running')

      # Later tick: the coordinator resumes the SAME intent inline and completes it.
      perform_enqueued_jobs(only: [process_inbox_job]) { drainer.perform_now }
      expect(run.reload.status).to eq('completed')
      expect(run_model.where(generation: 'gen-intent-fail').count).to eq(1)
    end
  end

  # A transient error while SELECTING the run intent (before the inline reconcile) must be swallowed by
  # the tick-level guard exactly like an inline reconciliation failure — otherwise it would escape
  # perform and let ActiveJob's Sidekiq default retry spin an independent, unbounded retry tree, one
  # per hourly cron tick under a persistent DB/query failure.
  describe 'a pre-reconcile failure is swallowed by the tick-level guard (no independent retry tree)' do
    it 'swallows a failing incomplete-run query across repeated ticks (no raise, no ReconciliationJob enqueue)' do
      allow(run_model).to receive(:incomplete).and_raise(ActiveRecord::StatementInvalid, 'incomplete query boom')
      expect(recon_job).not_to receive(:perform_later)
      expect(recon_job).not_to receive(:perform_now)
      expect(reconciler).not_to receive(:run)

      3.times { expect { drainer.perform_now }.not_to raise_error }

      expect(run_model.count).to eq(0) # the failing query aborted the tick before any run was created
    end

    it 'swallows a failing provenance exists? query across repeated ticks (no raise, no enqueue, no reconcile)' do
      # No incomplete run, so the coordinator advances to the provenance existence check, which raises.
      allow(provenance_model).to receive(:unreconciled).and_raise(ActiveRecord::StatementInvalid, 'provenance query boom')
      expect(recon_job).not_to receive(:perform_later)
      expect(recon_job).not_to receive(:perform_now)
      expect(reconciler).not_to receive(:run)

      3.times { expect { drainer.perform_now }.not_to raise_error }

      expect(run_model.count).to eq(0)
    end

    it 'swallows a failing fresh-intent find/create across repeated ticks (no raise, no enqueue, no reconcile)' do
      make_agent
      crash_gap_orphan # a genuine straggler exists, so the coordinator reaches find_or_create!
      allow(run_model).to receive(:find_or_create_by!).and_raise(ActiveRecord::RecordNotUnique, 'intent create boom')
      expect(recon_job).not_to receive(:perform_later)
      expect(recon_job).not_to receive(:perform_now)
      expect(reconciler).not_to receive(:run)

      3.times { expect { drainer.perform_now }.not_to raise_error }

      expect(run_model.where("generation LIKE 'recovery-%'").count).to eq(0)
    end
  end

  # Blocker E: the one-time reconciliation is a DURABLE persisted run intent (the migration INSERTs a
  # 'running' run row with started_at NULL), NOT a one-shot Redis perform_later. The drainer is the
  # coordinator: each tick it runs the Reconciler INLINE for the oldest incomplete run until it
  # truthfully completes, so the initial run cannot be lost to Redis downtime or old-worker timing.
  describe 'durable run-intent coordinator' do
    it 'resumes a persisted one-time run intent and completes it truthfully (scans zero, retries 0)' do
      make_agent
      # As persisted by the migration: never executed yet (started_at NULL), full-history cutoff.
      run = run_model.create!(generation: '20260912000003', status: 'running', started_at: nil, cutoff_at: Time.current)

      run_drainer

      expect(run.reload.status).to eq('completed')
      expect(run.scanned).to eq(0)             # no provenance on this install
      expect(run.retries).to eq(0)             # first execution of a pre-persisted intent is NOT a retry
      expect(run.started_at).to be_present      # coordinator stamped the actual execution start
    end

    it 'is idempotent: a completed run is never resumed on a later tick' do
      run_model.create!(generation: 'gen-intent', status: 'running', started_at: nil, cutoff_at: Time.current)
      run_drainer
      expect(run_model.find_by(generation: 'gen-intent').status).to eq('completed')

      expect(reconciler).not_to receive(:run)
      expect(recon_job).not_to receive(:perform_later)
      drainer.perform_now # the completed run is excluded from `incomplete`; no provenance to drain
    end

    it 'the persisted run intent has a unique generation, so it can never be duplicated' do
      run_model.create!(generation: '20260912000003', status: 'running', started_at: nil, cutoff_at: Time.current)
      # The unique generation (model validation + the backing unique index) guarantees one row per
      # generation, so the migration's INSERT-if-not-exists can never create a second run intent.
      expect do
        run_model.create!(generation: '20260912000003', status: 'running', started_at: nil, cutoff_at: Time.current)
      end.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  # Amplification guard (blocker): each tick must process AT MOST ONE persisted run intent inline and
  # must NOT open a new recovery generation while any incomplete run exists — otherwise a persistent
  # failure would accumulate one fresh generation per tick on top of the stuck run, and (previously)
  # enqueue them all repeatedly onto the :low queue, each with its own retry tree.
  describe 'bounded per tick (amplification guard)' do
    it 'keeps run growth flat under a persistently failing reconciler (one inline resume per tick, zero enqueues)' do
      make_agent
      crash_gap_orphan # unreconciled provenance older than the safety age (would otherwise be drainable)
      run_model.create!(generation: 'stuck', status: 'running', started_at: Time.current, cutoff_at: Time.current)

      generations = []
      allow(reconciler).to receive(:run) do |generation:, **_|
        generations << generation
        raise StandardError, 'persistent failure' # never completes; drainer swallows
      end
      expect(recon_job).not_to receive(:perform_later) # NEVER hands off to the second queue

      5.times { expect { drainer.perform_now }.not_to raise_error }

      expect(run_model.count).to eq(1)                              # no fresh recovery generation piled on
      expect(run_model.incomplete.pluck(:generation)).to eq(['stuck'])
      expect(generations).to eq(%w[stuck stuck stuck stuck stuck]) # exactly one inline call per tick, always the stuck run
    end

    it 'a pending initial intent blocks opening a recovery generation even with drainable provenance' do
      make_agent
      crash_gap_orphan
      run_model.create!(generation: '20260912000003', status: 'running', started_at: nil, cutoff_at: Time.current)
      allow(reconciler).to receive(:run) # stall: leave the intent incomplete

      expect { drainer.perform_now }.not_to change(run_model, :count)
      expect(run_model.where("generation LIKE 'recovery-%'").count).to eq(0)
      expect(reconciler).to have_received(:run).once.with(generation: '20260912000003', cutoff: anything)
    end

    it 'opens exactly one new recovery generation only once no incomplete run remains' do
      conversation, = crash_gap_orphan
      agent = make_agent
      @online = [agent.id.to_s]
      expect(run_model.incomplete).to be_empty

      run_drainer

      expect(run_model.where("generation LIKE 'recovery-%'").count).to eq(1)
      expect(conversation.reload.assignee_id).to be_present
    end
  end

  # The marker itself is the durable OUTBOX. Reconciler#dispatch is best-effort: a stale in-flight key
  # left by a crashed worker coalesces the dispatch away and later expires unconsumed, and because the
  # run is by then completed + its provenance reconciled, the crash-gap branch never re-sees it. So on
  # EVERY tick — first, and regardless of run/provenance state — the drainer redispatches a bounded
  # batch of the inboxes that currently hold markers, querying ONLY the battery marker table.
  describe 'durable marker outbox (redispatches still-present markers every tick)' do
    it 'coalesces under a stale in-flight key, then enqueues once the key expires — even after the run completed' do
      make_agent
      conversation, = crash_gap_orphan
      @online = [] # adopted but no online agent, so the marker is RETAINED (no_eligible_agent)

      run_drainer
      expect(marker_for(conversation)).to be_present                     # durable marker survives
      expect(provenance_row(conversation).reconciled_at).to be_present   # run completed, provenance reconciled
      expect(run_model.first.status).to eq('completed')

      inbox_id = conversation.inbox_id
      in_flight = format(process_inbox_job::IN_FLIGHT_KEY, inbox_id: inbox_id)
      rerun = format(process_inbox_job::RERUN_KEY, inbox_id: inbox_id)
      # A stale in-flight key from a since-crashed worker: no real job is queued/running for it.
      Redis::Alfred.set(in_flight, 'stale-token', ex: 300)

      # First tick: the marker drain coalesces against the stale key (records a rerun request), so it
      # enqueues NO new job — the coalescing stays authoritative, no storm.
      expect { drainer.perform_now }.not_to have_enqueued_job(process_inbox_job)
      expect(Redis::Alfred.get(rerun)).to be_present

      # TTL expiry: both keys expire with no worker having consumed them (the crashed-worker case).
      Redis::Alfred.delete(in_flight)
      Redis::Alfred.delete(rerun)

      # A later hourly tick now enqueues a real ProcessInboxJob for the still-present marker.
      expect { drainer.perform_now }.to have_enqueued_job(process_inbox_job)
    end

    it 'bounds the outbox per tick to MARKER_OUTBOX_BATCH distinct inboxes' do
      stub_const("#{drainer}::MARKER_OUTBOX_BATCH", 2)
      3.times { waiting_marker_on_new_inbox }
      expect(marker_model.count).to eq(3)

      expect { drainer.perform_now }.to have_enqueued_job(process_inbox_job).exactly(2).times
    end

    it 'scans ONLY the marker table — an intentionally-unassigned conversation with no marker drives no dispatch' do
      intentional = Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      intentional.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations
      marker_model.where(conversation_id: intentional.id).delete_all
      expect(marker_model.count).to eq(0)
      allow(marker_model).to receive(:distinct).and_call_original

      expect { drainer.perform_now }.not_to have_enqueued_job(process_inbox_job)
      expect(marker_model).to have_received(:distinct) # the outbox queries the marker table, nothing else
    end

    it 'enqueues nothing when there are no markers' do
      expect { drainer.perform_now }.not_to have_enqueued_job(process_inbox_job)
    end

    it 'repeated ticks against a live in-flight key coalesce — no job storm' do
      waiting_marker_on_new_inbox

      # Jobs are enqueued (not performed), so the first tick's in-flight key stays live and every
      # later tick coalesces against it: exactly one job across three ticks.
      expect { 3.times { drainer.perform_now } }.to have_enqueued_job(process_inbox_job).exactly(:once)
    end

    it 'swallows a marker-outbox dispatch failure via the whole-tick guard (no raise, no retry tree)' do
      waiting_marker_on_new_inbox
      allow(process_inbox_job).to receive(:enqueue_for_inbox).and_raise(StandardError, 'redis boom')
      expect(reconciler).not_to receive(:run) # the drain raises first; the tick guard swallows it

      expect { drainer.perform_now }.not_to raise_error
    end
  end
end
