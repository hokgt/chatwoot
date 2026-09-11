# frozen_string_literal: true

require 'rails_helper'

# Historical backfill for the deferred auto-assignment battery: an operator-invoked, one-time
# discovery/dry-run plus explicit-allowlist apply for conversations that became open +
# unassigned BEFORE the agent-deletion bridge existed (so they carry no marker). Discovery is
# provably read-only; apply fails closed on an empty allowlist, rejects cross-account/missing
# ids distinctly, is bounded and idempotent, and reuses the EXACT live pipeline
# (Eligibility -> Marker -> ProcessInboxJob -> InboxProcessor -> native AgentAssignmentService
# -> conversation.update! -> existing ERP owner-sync callback). It adds no selector, no direct
# assignee write, and no new ERP path.
RSpec.describe 'Deferred auto-assignment historical backfill', type: :model do
  let(:discovery) { Wijaya::Batteries::DeferredAutoAssignment::HistoricalDiscovery }
  let(:backfill) { Wijaya::Batteries::DeferredAutoAssignment::HistoricalBackfill }
  let(:backfill_job) { Wijaya::Batteries::DeferredAutoAssignment::BackfillJob }
  let(:process_inbox_job) { Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob }
  let(:marker_model) { Wijaya::Batteries::DeferredAutoAssignment::Marker }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:erp_owner_sync_job) { Wijaya::Batteries::ErpLeadOwnerSync::OwnerSyncJob }

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
    @online = []
    allow(OnlineStatusTracker).to receive(:get_available_users) { @online.index_with { 'online' } }
    allow(AutoAssignment::InboxRoundRobinService).to receive(:new).and_return(round_robin_picker)
    allow(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox)
    # ERP owner-sync is an EXISTING battery callback; stub only its enqueue so we assert the
    # seam is (or is not) reached, never a real ERP push.
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

  def marker_count(conversation)
    marker_model.where(conversation_id: conversation.id).count
  end

  # A pre-feature "historical" conversation: open + unassigned + NO marker, produced exactly
  # the way the real scenario does — assigned at creation (so no marker and no creation-time
  # enqueue), then its assignee cleared WITHOUT callbacks (mirroring Agents::DestroyJob's
  # update_all), leaving it open + unassigned with no marker and no stray in-flight key.
  def historical_conversation(params = {})
    @online = []
    placeholder = create(:user, account: account, role: :agent)
    conversation = Conversation.create!(
      { account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: placeholder }.merge(params)
    )
    conversation.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations
    # Guarantee a clean pre-feature row regardless of any creation-time routing: no marker and
    # no lingering per-inbox in-flight/rerun key that would coalesce away the apply's enqueue.
    marker_model.where(conversation_id: conversation.id).delete_all
    Redis::Alfred.delete(format(process_inbox_job::IN_FLIGHT_KEY, inbox_id: conversation.inbox_id))
    Redis::Alfred.delete(format(process_inbox_job::RERUN_KEY, inbox_id: conversation.inbox_id))
    conversation
  end

  # A live waiting conversation that DOES carry a marker (created offline, marker left intact).
  def marked_waiting_conversation(params = {})
    @online = []
    Conversation.create!({ account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox }.merge(params))
  end

  def link_erp_lead(conversation)
    Wijaya::ErpLeadDraft.create!(
      account: account, conversation: conversation, fields: {}, erp_lead_id: 'LEAD-0001', sync_status: 'draft'
    )
  end

  # Drive the REAL apply pipeline end to end: HistoricalBackfill.run enqueues one BackfillJob,
  # which marks eligible ids and enqueues the coalesced ProcessInboxJob that assigns.
  def run_apply(ids)
    perform_enqueued_jobs(only: [backfill_job, process_inbox_job]) do
      backfill.run(account_id: account.id, conversation_ids: ids)
    end
  end

  describe 'discovery / dry run' do
    it 'is read-only: writes nothing, enqueues nothing, assigns nothing' do
      make_agent
      conversation = historical_conversation

      result = nil
      expect { result = discovery.discover(account_id: account.id, limit: 100) }
        .not_to change(marker_model, :count)
      expect { discovery.discover(account_id: account.id, limit: 100) }.not_to have_enqueued_job
      expect(conversation.reload.assignee_id).to be_nil

      row = result.find { |r| r[:conversation_id] == conversation.id }
      expect(row).to be_present
      expect(row[:marker_present]).to be(false)
      expect(row[:deferrable]).to be(true)
      expect(row[:status]).to eq('open')
    end

    it 'reports evidence keys including apparent_target and linked ERP lead presence' do
      make_agent
      team = create(:team, account: account, allow_auto_assign: true)
      conversation = historical_conversation(team: team)
      link_erp_lead(conversation)

      row = discovery.discover(account_id: account.id).find { |r| r[:conversation_id] == conversation.id }

      expect(row[:apparent_target]).to be_in(%i[current_agent current_team deleted_or_unknown ambiguous])
      expect(row[:linked_erp_lead]).to be(true)
      expect(row).to include(:created_at, :updated_at, :inbox_id, :latest_assignment_activity)
    end

    it 'is bounded by an explicit limit and never loads unbounded' do
      make_agent
      3.times { historical_conversation }

      expect(discovery.discover(account_id: account.id, limit: 2).size).to eq(2)
    end

    it 'excludes conversations that already carry a marker from default discovery' do
      make_agent
      marked = marked_waiting_conversation

      ids = discovery.discover(account_id: account.id).map { |r| r[:conversation_id] }
      expect(ids).not_to include(marked.id)
    end

    it 'returns no rows for an explicit EMPTY allowlist (never falls back to the default scan)' do
      make_agent
      historical_conversation # a default-scan candidate exists

      expect(discovery.discover(account_id: account.id, conversation_ids: [])).to eq([])
      # nil (no allowlist) still performs the default discovery.
      expect(discovery.discover(account_id: account.id, conversation_ids: nil)).not_to be_empty
    end
  end

  # apparent_target is evidence only — a best-effort label parsed from the latest assignment
  # activity, never used for approval or apply. Exercised directly (module_function) so the
  # activity content is deterministic and not subject to created_at ordering of seeded rows.
  describe 'apparent_target classification (evidence only)' do
    let(:conversation) { historical_conversation }

    def activity_for(content)
      { id: 1, created_at: conversation.created_at, content: content }
    end

    it 'labels a name matching a current account user (only) current_agent' do
      agent = create(:user, account: account, name: 'Dana Agent', role: :agent)
      expect(discovery.classify(conversation, activity_for("Assigned to #{agent.name} by the System"))).to eq(:current_agent)
    end

    it 'is case-insensitive when matching a user name' do
      create(:user, account: account, name: 'Dana Agent', role: :agent)
      expect(discovery.classify(conversation, activity_for('Assigned to dana agent by the System'))).to eq(:current_agent)
    end

    it 'labels a name matching a current account team (only) current_team' do
      team = create(:team, account: account, name: 'Sales Squad')
      expect(discovery.classify(conversation, activity_for("Assigned to #{team.name} by the System"))).to eq(:current_team)
    end

    it 'labels a name matching neither a user nor a team deleted_or_unknown' do
      expect(discovery.classify(conversation, activity_for('Assigned to Ghost McMissing by the System'))).to eq(:deleted_or_unknown)
    end

    it 'labels a name matching BOTH a user and a team ambiguous' do
      create(:user, account: account, name: 'Overlap', role: :agent)
      create(:team, account: account, name: 'Overlap')
      expect(discovery.classify(conversation, activity_for('Assigned to Overlap by the System'))).to eq(:ambiguous)
    end

    it 'is ambiguous when there is no activity' do
      expect(discovery.classify(conversation, nil)).to eq(:ambiguous)
    end

    it 'is ambiguous when the activity names no parseable target' do
      expect(discovery.classify(conversation, activity_for('Auto assignment was skipped'))).to eq(:ambiguous)
    end
  end

  describe 'apply: allowlist gating' do
    it 'enqueues a bounded BackfillJob for ONLY the explicit allowlisted ids' do
      keep = historical_conversation
      other = historical_conversation

      expect { backfill.run(account_id: account.id, conversation_ids: [keep.id]) }
        .to have_enqueued_job(backfill_job).with(account_id: account.id, conversation_ids: [keep.id])
      # The un-allowlisted conversation never enters apply.
      expect(marker_for(other)).to be_nil
    end

    it 'fails closed on a missing/empty allowlist and enqueues nothing' do
      expect { backfill.run(account_id: account.id, conversation_ids: []) }.to raise_error(ArgumentError)
      expect { backfill.run(account_id: account.id, conversation_ids: nil) }.to raise_error(ArgumentError)
      expect { backfill.run(account_id: account.id, conversation_ids: '') }.to raise_error(ArgumentError)
      expect(enqueued_jobs.select { |job| job[:job] == backfill_job }).to be_empty
    end

    it 'fails closed on a missing account id' do
      conversation = historical_conversation
      expect { backfill.run(account_id: 0, conversation_ids: [conversation.id]) }.to raise_error(ArgumentError)
    end

    it 'fails closed on a well-formed but non-existent account id and enqueues nothing' do
      missing_account_id = account.id + 100_000
      expect { backfill.run(account_id: missing_account_id, conversation_ids: [1]) }.to raise_error(ArgumentError)
      expect(enqueued_jobs.select { |job| job[:job] == backfill_job }).to be_empty
    end

    it 'fails closed on a malformed/non-positive id token instead of partially applying' do
      keep = historical_conversation

      %w[abc 1.5 0 -3].each do |bad|
        expect { backfill.run(account_id: account.id, conversation_ids: "#{keep.id},#{bad}") }.to raise_error(ArgumentError)
      end
      expect { backfill.run(account_id: account.id, conversation_ids: [keep.id, 'abc']) }.to raise_error(ArgumentError)
      # Nothing was enqueued for the partially-valid allowlist.
      expect(enqueued_jobs.select { |job| job[:job] == backfill_job }).to be_empty
    end

    it 'dedupes repeated valid ids from a string or array allowlist' do
      keep = historical_conversation

      expect { backfill.run(account_id: account.id, conversation_ids: "#{keep.id}, #{keep.id}") }
        .to have_enqueued_job(backfill_job).with(account_id: account.id, conversation_ids: [keep.id])
      expect { backfill.run(account_id: account.id, conversation_ids: [keep.id, keep.id]) }
        .to have_enqueued_job(backfill_job).with(account_id: account.id, conversation_ids: [keep.id])
    end

    it 'rejects cross-account ids DISTINCTLY from missing ids and enqueues neither' do
      other_account = create(:account)
      other_inbox = create(:inbox, account: other_account, enable_auto_assignment: true)
      other_contact = create(:contact, account: other_account)
      cross = create(:conversation, account: other_account, inbox: other_inbox, contact: other_contact,
                                    contact_inbox: create(:contact_inbox, contact: other_contact, inbox: other_inbox))
      missing_id = cross.id + 10_000

      summary = backfill.run(account_id: account.id, conversation_ids: [cross.id, missing_id])

      expect(summary[:cross_account]).to eq([cross.id])
      expect(summary[:missing]).to eq([missing_id])
      expect(summary[:enqueued]).to be_empty
      expect(enqueued_jobs.select { |job| job[:job] == backfill_job }).to be_empty
    end
  end

  describe 'apply: rechecks skip stale / ineligible records' do
    it 'skips an already-assigned conversation (no marker, no overwrite)' do
      agent = make_agent
      spv = make_agent
      conversation = historical_conversation
      conversation.update!(assignee: spv) # already claimed before apply

      @online = [agent.id.to_s]
      run_apply([conversation.id])

      expect(conversation.reload.assignee).to eq(spv)
      expect(marker_for(conversation)).to be_nil
    end

    it 'skips a conversation manually assigned BETWEEN discovery and execution' do
      agent = make_agent
      spv = make_agent
      conversation = historical_conversation
      # Discovery saw it as deferrable...
      expect(discovery.discover(account_id: account.id, conversation_ids: [conversation.id]).first[:deferrable]).to be(true)
      # ...then a supervisor claims it before the queued job runs.
      conversation.update!(assignee: spv)

      @online = [agent.id.to_s]
      run_apply([conversation.id])

      expect(conversation.reload.assignee).to eq(spv)
      expect(marker_for(conversation)).to be_nil
    end

    it 'skips a resolved (non-open) conversation' do
      agent = make_agent
      conversation = historical_conversation
      conversation.update_columns(status: Conversation.statuses[:resolved]) # rubocop:disable Rails/SkipsModelValidations

      @online = [agent.id.to_s]
      run_apply([conversation.id])

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_nil
    end

    it 'skips an agent-bot–owned conversation' do
      agent = make_agent
      agent_bot = create(:agent_bot, account: account)
      conversation = historical_conversation
      conversation.update_column(:assignee_agent_bot_id, agent_bot.id) # rubocop:disable Rails/SkipsModelValidations

      @online = [agent.id.to_s]
      run_apply([conversation.id])

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_nil
    end

    it 'SKIPS a conversation that already carries a marker: no re-mark and no historical enqueue' do
      make_agent
      conversation = marked_waiting_conversation
      expect(marker_count(conversation)).to eq(1)

      # Spy installed AFTER creation, so only the historical path's (non-)enqueue is observed.
      allow(process_inbox_job).to receive(:enqueue_for_inbox)
      @online = [] # nobody online either way

      Wijaya::Batteries::DeferredAutoAssignment::Registrar.register_unassigned_historical(account.id, [conversation.id])

      expect(marker_count(conversation)).to eq(1)
      expect(process_inbox_job).not_to have_received(:enqueue_for_inbox)
    end

    it 'is a safe no-op for a conversation deleted before the job runs' do
      conversation = historical_conversation
      deleted_id = conversation.id
      conversation.destroy!

      expect do
        Wijaya::Batteries::DeferredAutoAssignment::Registrar.register_unassigned_historical(account.id, [deleted_id])
      end.not_to raise_error
      expect(marker_model.where(conversation_id: deleted_id).count).to eq(0)
    end
  end

  describe 'apply: assignment through the existing pipeline' do
    it 'assigns an eligible online agent via the native processor and clears the marker' do
      agent = make_agent
      conversation = historical_conversation

      @online = [agent.id.to_s]
      run_apply([conversation.id])

      expect(conversation.reload.assignee).to eq(agent)
      expect(marker_for(conversation)).to be_nil
    end

    it 'leaves the conversation unassigned WITH the marker retained when nobody is available' do
      make_agent # an offline inbox member exists
      conversation = historical_conversation

      @online = [] # nobody online when the queued job runs
      run_apply([conversation.id])

      expect(conversation.reload.assignee_id).to be_nil
      expect(marker_for(conversation)).to be_present
    end

    it 'is idempotent across a retried apply' do
      make_agent
      conversation = historical_conversation

      @online = []
      run_apply([conversation.id])
      expect(marker_count(conversation)).to eq(1)

      # A retried apply for the same id neither duplicates the marker nor errors.
      run_apply([conversation.id])
      expect(marker_count(conversation)).to eq(1)
      expect(conversation.reload.assignee_id).to be_nil
    end
  end

  describe 'apply: ERP owner sync reuses the existing path only' do
    it 'invokes the existing owner-sync enqueue when a lead is linked' do
      agent = make_agent
      conversation = historical_conversation
      link_erp_lead(conversation)

      @online = [agent.id.to_s]
      run_apply([conversation.id])

      expect(conversation.reload.assignee).to eq(agent)
      expect(erp_owner_sync_job).to have_received(:perform_later).with(conversation.id, agent.id)
    end

    it 'enqueues no owner sync when there is no linked ERP lead' do
      agent = make_agent
      conversation = historical_conversation

      @online = [agent.id.to_s]
      run_apply([conversation.id])

      expect(conversation.reload.assignee).to eq(agent)
      expect(erp_owner_sync_job).not_to have_received(:perform_later)
    end
  end

  describe 'BackfillJob direct-call defense: fails closed, never silently truncates' do
    it 'raises and does no work for an oversized batch instead of truncating to MAX_BATCH' do
      oversized = (1..(backfill::MAX_BATCH + 1)).to_a

      expect { backfill_job.perform_now(account_id: account.id, conversation_ids: oversized) }
        .to raise_error(ArgumentError)
      expect(marker_model.count).to eq(0)
    end

    it 'raises for an empty, non-Array, or non-positive-integer payload' do
      expect { backfill_job.perform_now(account_id: account.id, conversation_ids: []) }.to raise_error(ArgumentError)
      expect { backfill_job.perform_now(account_id: account.id, conversation_ids: '1,2') }.to raise_error(ArgumentError)
      expect { backfill_job.perform_now(account_id: account.id, conversation_ids: [1, 0]) }.to raise_error(ArgumentError)
      expect { backfill_job.perform_now(account_id: account.id, conversation_ids: [1, -2]) }.to raise_error(ArgumentError)
      expect { backfill_job.perform_now(account_id: account.id, conversation_ids: ['1']) }.to raise_error(ArgumentError)
    end

    it 'processes a valid direct-call payload through the shared historical entry point' do
      agent = make_agent
      conversation = historical_conversation

      @online = [agent.id.to_s]
      perform_enqueued_jobs(only: [process_inbox_job]) do
        backfill_job.perform_now(account_id: account.id, conversation_ids: [conversation.id])
      end

      expect(conversation.reload.assignee).to eq(agent)
    end
  end

  # BackfillOperator is the canonical runner adapter (the bin/historical_backfill.rb script is a
  # tiny wrapper around it). These exercise its MODE/APPLY gating directly with an injected env
  # hash + StringIO — no subprocess — and stub the services so only the operator's argument
  # parsing / fail-closed gating is under test, never the pipeline itself.
  describe 'BackfillOperator: MODE / APPLY gating (canonical runner adapter)' do
    let(:operator) { Wijaya::Batteries::DeferredAutoAssignment::BackfillOperator }
    let(:out) { StringIO.new }

    def run_operator(env)
      operator.call(env: env, out: out)
    end

    it 'defaults to read-only discovery when MODE is absent and never applies' do
      allow(discovery).to receive(:discover).and_return([])
      allow(backfill).to receive(:run)

      run_operator({ 'ACCOUNT_ID' => '7' })

      expect(discovery).to have_received(:discover).with(account_id: 7, limit: 100, inbox_id: nil, conversation_ids: nil)
      expect(backfill).not_to have_received(:run)
      expect(out.string).to include('DRY RUN').and include('never approval')
    end

    it 'passes bounded LIMIT, a normalized INBOX_ID and a CONVERSATION_IDS preview through discovery' do
      allow(discovery).to receive(:discover).and_return([])

      run_operator({ 'MODE' => 'discover', 'ACCOUNT_ID' => '7', 'LIMIT' => '5', 'INBOX_ID' => '3',
                     'CONVERSATION_IDS' => '10, 11' })

      # LIMIT and INBOX_ID reach discovery as normalized Integers, never raw strings.
      expect(discovery).to have_received(:discover).with(account_id: 7, limit: 5, inbox_id: 3, conversation_ids: %w[10 11])
    end

    it 'fails closed on a malformed ACCOUNT_ID instead of coercing it via to_i' do
      allow(discovery).to receive(:discover)

      %w[3abc 1.5 abc].each do |bad|
        expect { run_operator({ 'ACCOUNT_ID' => bad }) }.to raise_error(ArgumentError, /ACCOUNT_ID/)
      end
      expect(discovery).not_to have_received(:discover)
    end

    it 'fails closed on a malformed or non-positive LIMIT and does no discovery' do
      allow(discovery).to receive(:discover)

      %w[5abc 1.5 0 -3].each do |bad|
        expect { run_operator({ 'ACCOUNT_ID' => '7', 'LIMIT' => bad }) }.to raise_error(ArgumentError, /LIMIT/)
      end
      expect(discovery).not_to have_received(:discover)
    end

    it 'fails closed on a malformed or non-positive INBOX_ID and does no discovery' do
      allow(discovery).to receive(:discover)

      %w[3abc 1.5 0 -3].each do |bad|
        expect { run_operator({ 'ACCOUNT_ID' => '7', 'INBOX_ID' => bad }) }.to raise_error(ArgumentError, /INBOX_ID/)
      end
      expect(discovery).not_to have_received(:discover)
    end

    it 'defaults LIMIT and omits INBOX_ID when they are absent (no spurious validation)' do
      allow(discovery).to receive(:discover).and_return([])

      run_operator({ 'ACCOUNT_ID' => '7' })

      expect(discovery).to have_received(:discover).with(account_id: 7, limit: 100, inbox_id: nil, conversation_ids: nil)
    end

    it 'reports that NO BackfillJob was enqueued when the apply summary has no in-account ids' do
      allow(backfill).to receive(:run).and_return(enqueued: [], cross_account: [9], missing: [10])

      run_operator({ 'MODE' => 'apply', 'ACCOUNT_ID' => '7', 'APPLY' => '1', 'CONVERSATION_IDS' => '9,10' })

      expect(out.string).to include('No BackfillJob was enqueued')
      expect(out.string).not_to include('A single bounded BackfillJob was enqueued')
    end

    it 'fails closed on an unknown MODE and does no work' do
      allow(discovery).to receive(:discover)
      allow(backfill).to receive(:run)

      expect { run_operator({ 'MODE' => 'nuke', 'ACCOUNT_ID' => '7' }) }.to raise_error(ArgumentError, /unknown MODE/)
      expect(discovery).not_to have_received(:discover)
      expect(backfill).not_to have_received(:run)
    end

    it 'requires an explicit positive ACCOUNT_ID' do
      expect { run_operator({}) }.to raise_error(ArgumentError, /ACCOUNT_ID/)
      expect { run_operator({ 'ACCOUNT_ID' => '0' }) }.to raise_error(ArgumentError, /ACCOUNT_ID/)
      expect { run_operator({ 'ACCOUNT_ID' => '-2' }) }.to raise_error(ArgumentError, /ACCOUNT_ID/)
    end

    it 'refuses apply without APPLY=1 and enqueues nothing' do
      allow(backfill).to receive(:run)

      expect { run_operator({ 'MODE' => 'apply', 'ACCOUNT_ID' => '7', 'CONVERSATION_IDS' => '1,2' }) }
        .to raise_error(ArgumentError, /APPLY=1/)
      expect(backfill).not_to have_received(:run)
    end

    it 'refuses apply when APPLY=1 but CONVERSATION_IDS is missing or blank' do
      allow(backfill).to receive(:run)

      expect { run_operator({ 'MODE' => 'apply', 'ACCOUNT_ID' => '7', 'APPLY' => '1' }) }
        .to raise_error(ArgumentError, /non-empty CONVERSATION_IDS/)
      expect { run_operator({ 'MODE' => 'apply', 'ACCOUNT_ID' => '7', 'APPLY' => '1', 'CONVERSATION_IDS' => '   ' }) }
        .to raise_error(ArgumentError, /non-empty CONVERSATION_IDS/)
      expect(backfill).not_to have_received(:run)
    end

    it 'delegates to HistoricalBackfill.run ONLY when MODE=apply AND APPLY=1 AND ids are present' do
      allow(backfill).to receive(:run).and_return(enqueued: [1, 2], cross_account: [], missing: [])

      run_operator({ 'MODE' => 'apply', 'ACCOUNT_ID' => '7', 'APPLY' => '1', 'CONVERSATION_IDS' => '1,2' })

      expect(backfill).to have_received(:run).with(account_id: 7, conversation_ids: '1,2')
      expect(out.string).to include('APPLY').and include('BackfillJob')
    end
  end
end
