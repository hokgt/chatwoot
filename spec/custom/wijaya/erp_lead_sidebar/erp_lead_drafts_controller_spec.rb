# frozen_string_literal: true

require 'rails_helper'

# Zero-draft safety: opening the ERP Lead sidebar must never persist a draft row
# while the ERPNext connection is unconfigured. Only a configured ERP may create
# a draft on open.
RSpec.describe 'Wijaya ERP Lead Drafts API', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:agent) { create(:user, account: account, role: :agent) }

  let(:base_path) do
    "/api/v1/accounts/#{account.id}/wijaya/erp_lead_drafts/#{conversation.display_id}"
  end
  let(:show_path) { base_path }
  let(:update_path) { base_path }
  let(:sync_path) { "#{base_path}/sync" }
  let(:auth) { { api_access_token: agent.access_token.token } }

  before { create(:inbox_member, inbox: inbox, user: agent) }

  def open_sidebar
    get show_path, headers: auth, as: :json
  end

  context 'when ERP is not configured' do
    before do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(false)
    end

    it 'renders the panel without creating any draft row on open' do
      expect { open_sidebar }.not_to change(Wijaya::ErpLeadDraft, :count).from(0)

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['configured']).to be(false)
    end

    # Zero-side-effect contract for GET show: no outbound ERP request may leave the
    # process while unconfigured. WebMock (disable_net_connect!) already fails any real
    # external call; this makes the "no outbound path" assertion explicit.
    it 'performs no outbound ERP request and no sync on open' do
      expect(Net::HTTP).not_to receive(:start)
      expect(Wijaya::Batteries::ErpLeadSidebar::SyncService).not_to receive(:new)

      open_sidebar

      expect(response.parsed_body['configured']).to be(false)
    end

    it 'PATCH update persists zero rows, never syncs, and reports configured:false' do
      expect(Net::HTTP).not_to receive(:start)
      expect(Wijaya::Batteries::ErpLeadSidebar::SyncService).not_to receive(:new)

      expect do
        patch update_path, params: { fields: { first_name: 'Nope' } }, headers: auth, as: :json
      end.not_to change(Wijaya::ErpLeadDraft, :count).from(0)

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['configured']).to be(false)
    end

    it 'POST sync with fields persists zero rows, never calls SyncService, and reports configured:false' do
      expect(Net::HTTP).not_to receive(:start)
      expect(Wijaya::Batteries::ErpLeadSidebar::SyncService).not_to receive(:new)

      expect do
        post sync_path, params: { fields: { first_name: 'Nope', mobile_no: '123' } }, headers: auth, as: :json
      end.not_to change(Wijaya::ErpLeadDraft, :count).from(0)

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['configured']).to be(false)
    end
  end

  context 'when ERP is configured' do
    let(:options_service) do
      instance_double(Wijaya::Batteries::ErpLeadSidebar::OptionsService, fetch_all: {})
    end

    before do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(true)
      allow(Wijaya::Batteries::ErpLeadSidebar::OptionsService).to receive(:new).and_return(options_service)
    end

    it 'creates exactly one draft row on open' do
      expect { open_sidebar }.to change(Wijaya::ErpLeadDraft, :count).by(1)

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['configured']).to be(true)
    end

    # The Lead Owner options are the current account's own Chatwoot agents (email as value),
    # sourced from the local DB — never the ERPNext User list — so opening the sidebar issues
    # no outbound ERP request just to populate the picker.
    it 'serializes the account Chatwoot agents as the owner options (email value) with no ERP call' do
      admin = create(:user, account: account, role: :administrator, email: 'admin@example.com')
      create(:user, account: create(:account), role: :agent, email: 'elsewhere@example.com')
      expect(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).not_to receive(:request)

      open_sidebar

      body = response.parsed_body
      expect(body['owner_options_available']).to be(true)
      values = body['owner_options'].pluck('value')
      expect(values).to include(agent.email, admin.email)
      expect(values).not_to include('elsewhere@example.com')
      # value and label are both the agent email (the displayed value is clearly the email).
      body['owner_options'].each { |option| expect(option['label']).to eq(option['value']) }
    end

    # The owner is never an accepted draft input: it is set server-side post-link from the
    # validated assignee email. An untrusted lead_owner in the PATCH body must be dropped
    # by strong params and never persisted onto the draft.
    it 'never persists an untrusted lead_owner from the update body' do
      patch update_path,
            params: { fields: { first_name: 'Bob', lead_owner: 'attacker@evil.example' } },
            headers: auth, as: :json

      expect(response).to have_http_status(:success)
      draft = Wijaya::ErpLeadDraft.find_by(conversation: conversation)
      expect(draft.fields).not_to have_key('lead_owner')
      expect(draft.fields['first_name']).to eq('Bob')
    end
  end

  # Dedicated, validated Lead Owner set/reset endpoint. The owner is never trusted from
  # the browser: every nonblank value is reconfirmed to be a current-account Chatwoot
  # agent (AccountAgentDirectory) before it is stored, and the actual owner-only ERP
  # write — still fail-closed ERP-User validated — is owned by OwnerSyncJob.
  context 'with the Lead Owner endpoint' do
    let(:owner_path) { "#{base_path}/owner" }
    let(:owner_job) { Wijaya::Batteries::ErpLeadOwnerSync::OwnerSyncJob }
    # A real current-account Chatwoot agent whose email is the manual owner under test.
    let!(:owner_agent) { create(:user, account: account, role: :agent, email: 'boss@example.com') }

    before do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(true)
      allow(owner_job).to receive(:perform_later)
    end

    def linked_draft
      Wijaya::ErpLeadDraft.create!(
        account: account, conversation: conversation, fields: { 'first_name' => 'Bob' },
        erp_lead_id: 'LEAD-1', sync_status: 'synced'
      )
    end

    it 'stores a current-account agent owner as a sticky override + pending marker and enqueues the ERP sync' do
      draft = linked_draft

      post owner_path, params: { owner: 'boss@example.com' }, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['lead_owner']).to eq('boss@example.com')
      expect(response.parsed_body['lead_owner_override']).to be(true)
      draft.reload
      expect(draft.fields['lead_owner']).to eq('boss@example.com')
      expect(draft.fields['lead_owner_override']).to be(true)
      # Local storage is not proof of ERP sync: the pending marker forces a real PUT.
      expect(draft.fields['lead_owner_sync_pending']).to be(true)
      expect(owner_job).to have_received(:perform_later).with(conversation.id, conversation.assignee_id)
    end

    it 'reports a sanitized failure (not success) and leaves pending state when the manual sync cannot be queued' do
      draft = linked_draft
      allow(owner_job).to receive(:perform_later).and_raise(StandardError, 'queue down')

      post owner_path, params: { owner: 'boss@example.com' }, headers: auth, as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body['error']).to be_present
      expect(response.parsed_body['message']).to be_nil
      draft.reload
      # Retryable pending state persists so the owner is not stranded.
      expect(draft.fields['lead_owner']).to eq('boss@example.com')
      expect(draft.fields['lead_owner_override']).to be(true)
      expect(draft.fields['lead_owner_sync_pending']).to be(true)
    end

    # The server independently rejects a fabricated owner email that is not a current-account
    # Chatwoot agent even though the browser could submit anything: nothing is stored, no sync queued.
    it 'rejects a fabricated non-agent owner with a sanitized error, writing nothing and enqueuing no sync' do
      draft = linked_draft

      post owner_path, params: { owner: 'attacker@evil.example' }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to be_present
      draft.reload
      expect(draft.fields).not_to have_key('lead_owner')
      expect(draft.fields).not_to have_key('lead_owner_override')
      expect(owner_job).not_to have_received(:perform_later)
    end

    # An agent that belongs only to ANOTHER account is not a current-account agent and is rejected.
    it 'rejects an owner that is an agent only of another account' do
      draft = linked_draft
      stranger = create(:user, account: create(:account), role: :agent, email: 'elsewhere@example.com')

      post owner_path, params: { owner: stranger.email }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      draft.reload
      expect(draft.fields).not_to have_key('lead_owner')
      expect(owner_job).not_to have_received(:perform_later)
    end

    # Reset must prove the CURRENT committed assignee is a current-account Chatwoot agent
    # before clearing the override, so it can never drop the manual owner on a false
    # success while ERP still holds it.
    def overridden_linked_draft
      draft = Wijaya::ErpLeadDraft.create!(
        account: account, conversation: conversation, sync_status: 'synced',
        fields: { 'lead_owner' => 'boss@example.com', 'lead_owner_override' => true }
      )
      draft.update_column(:erp_lead_id, 'LEAD-1') # rubocop:disable Rails/SkipsModelValidations
      draft
    end

    it 'reset clears the override, marks the owner sync pending and resumes assignee-driven sync when the assignee is an agent' do
      draft = overridden_linked_draft
      conversation.update_column(:assignee_id, agent.id) # rubocop:disable Rails/SkipsModelValidations

      post owner_path, params: { reset: true }, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['lead_owner_override']).to be(false)
      draft.reload
      expect(draft.fields).not_to have_key('lead_owner_override')
      expect(draft.fields).not_to have_key('lead_owner')
      expect(draft.fields['lead_owner_sync_pending']).to be(true)
      expect(owner_job).to have_received(:perform_later).with(conversation.id, conversation.assignee_id)
    end

    it 'reset with no assignee preserves the manual owner + override, sends no PUT and enqueues nothing' do
      draft = overridden_linked_draft # conversation has no assignee

      post owner_path, params: { reset: true }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to be_present
      draft.reload
      expect(draft.fields['lead_owner']).to eq('boss@example.com')
      expect(draft.fields['lead_owner_override']).to be(true)
      expect(draft.fields).not_to have_key('lead_owner_sync_pending')
      expect(owner_job).not_to have_received(:perform_later)
    end

    it 'reset fails closed when the assignee is not a current-account agent, preserving the override' do
      draft = overridden_linked_draft
      stranger = create(:user) # not a member of this account
      conversation.update_column(:assignee_id, stranger.id) # rubocop:disable Rails/SkipsModelValidations

      post owner_path, params: { reset: true }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      draft.reload
      expect(draft.fields['lead_owner']).to eq('boss@example.com')
      expect(draft.fields['lead_owner_override']).to be(true)
      expect(draft.fields).not_to have_key('lead_owner_sync_pending')
      expect(owner_job).not_to have_received(:perform_later)
    end

    it 'keeps the manual owner + override across an ordinary field autosave' do
      draft = linked_draft
      post owner_path, params: { owner: 'boss@example.com' }, headers: auth, as: :json

      patch update_path, params: { fields: { first_name: 'Bob Edited' } }, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      draft.reload
      expect(draft.fields['first_name']).to eq('Bob Edited')
      expect(draft.fields['lead_owner']).to eq('boss@example.com')
      expect(draft.fields['lead_owner_override']).to be(true)
      # A routine field autosave must not drop the server-managed pending marker either.
      expect(draft.fields['lead_owner_sync_pending']).to be(true)
    end

    # The sidebar consumes lead_owner_sync_pending to render the pending/failed status and the
    # Retry action, so a truthful "saved but not yet in ERP" message must ride the response.
    it 'serializes lead_owner_sync_pending and a truthful (not "updated") manual message' do
      linked_draft

      post owner_path, params: { owner: 'boss@example.com' }, headers: auth, as: :json

      expect(response.parsed_body['lead_owner_sync_pending']).to be(true)
      expect(response.parsed_body['message']).to include('syncing to ERP')
      expect(response.parsed_body['message']).not_to include('updated')
    end

    # A failed/pending manual owner must be retryable WITHOUT re-picking it: the retry reconfirms
    # the current sticky owner and re-enqueues the same mode/target, touching no unrelated field.
    it 'retry reconfirms and re-enqueues the sticky manual owner, leaving other fields untouched' do
      draft = linked_draft
      post owner_path, params: { owner: 'boss@example.com' }, headers: auth, as: :json

      post owner_path, params: { retry: true }, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(owner_job).to have_received(:perform_later).with(conversation.id, conversation.assignee_id).twice
      draft.reload
      expect(draft.fields['lead_owner']).to eq('boss@example.com')
      expect(draft.fields['lead_owner_override']).to be(true)
      expect(draft.fields['lead_owner_sync_pending']).to be(true)
      expect(draft.fields['first_name']).to eq('Bob')
    end

    it 'retry in automatic mode reconfirms the current assignee and re-enqueues' do
      draft = Wijaya::ErpLeadDraft.create!(
        account: account, conversation: conversation, erp_lead_id: 'LEAD-1', sync_status: 'failed',
        fields: { 'first_name' => 'Bob', 'lead_owner' => agent.email, 'lead_owner_sync_pending' => true }
      )
      conversation.update_column(:assignee_id, agent.id) # rubocop:disable Rails/SkipsModelValidations

      post owner_path, params: { retry: true }, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(owner_job).to have_received(:perform_later).with(conversation.id, agent.id)
      expect(draft.reload.fields['lead_owner_sync_pending']).to be(true)
    end

    it 'retry fails closed (422) when the desired owner is no longer a current-account agent, enqueuing nothing' do
      draft = linked_draft
      draft.update!(fields: draft.fields.merge('lead_owner' => 'ghost@example.com', 'lead_owner_override' => true, 'lead_owner_sync_pending' => true))

      post owner_path, params: { retry: true }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to be_present
      expect(owner_job).not_to have_received(:perform_later)
    end

    it 'retry on an unlinked draft explains it will sync after creation and enqueues nothing' do
      Wijaya::ErpLeadDraft.create!(
        account: account, conversation: conversation, sync_status: 'draft',
        fields: { 'lead_owner' => 'boss@example.com', 'lead_owner_override' => true, 'lead_owner_sync_pending' => true }
      )

      post owner_path, params: { retry: true }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to be_present
      expect(owner_job).not_to have_received(:perform_later)
    end

    # Create/Update Lead must carry a confirmed-but-pending owner to ERP once the Lead is linked.
    # The owner has its own idempotent job, so an extra enqueue here is safe.
    it 'the full Lead sync re-enqueues a pending owner once the Lead is linked' do
      allow(Wijaya::Batteries::ErpLeadSidebar::OptionsService).to receive(:new).and_return(
        instance_double(Wijaya::Batteries::ErpLeadSidebar::OptionsService, fetch_all: {})
      )
      draft = Wijaya::ErpLeadDraft.create!(
        account: account, conversation: conversation, sync_status: 'synced',
        fields: { 'first_name' => 'Bob', 'status' => 'Lead', 'industry' => 'Retail',
                  'lead_owner' => 'boss@example.com', 'lead_owner_override' => true, 'lead_owner_sync_pending' => true }
      )
      # Link via update_column so the after_commit link seam does not fire here; this isolates
      # the sync action's own carry-the-pending-owner enqueue (create/link already covers linkage).
      draft.update_column(:erp_lead_id, 'LEAD-1') # rubocop:disable Rails/SkipsModelValidations
      sync_double = instance_double(
        Wijaya::Batteries::ErpLeadSidebar::SyncService, perform: { payload: {}, erp_lead_id: 'LEAD-1' }
      )
      allow(Wijaya::Batteries::ErpLeadSidebar::SyncService).to receive(:new).and_return(sync_double)

      post "#{base_path}/sync", headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(owner_job).to have_received(:perform_later).with(conversation.id, conversation.assignee_id).once
    end

    # Opening the sidebar on a synced Lead whose manual owner is still pending must NOT claim a
    # clean refresh: it preserves the local owner and returns a truthful owner-pending status.
    it 'show reports owner-pending (not "Refreshed") and preserves the local owner while pending' do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive_messages(
        erp_configured?: true, erp_base_url: 'https://erp.example.com', erp_api_key: 'k', erp_api_secret: 's'
      )
      allow(Wijaya::Batteries::ErpLeadSidebar::OptionsService).to receive(:new).and_return(
        instance_double(Wijaya::Batteries::ErpLeadSidebar::OptionsService, fetch_all: {})
      )
      Wijaya::ErpLeadDraft.create!(
        account: account, conversation: conversation, erp_lead_id: 'LEAD-1', sync_status: 'synced',
        fields: { 'first_name' => 'Local', 'lead_owner' => 'boss@example.com',
                  'lead_owner_override' => true, 'lead_owner_sync_pending' => true }
      )
      remote = Net::HTTPOK.new('1.1', '200', 'OK')
      allow(remote).to receive(:body).and_return(
        { 'data' => { 'first_name' => 'Remote', 'lead_owner' => 'someone-else@example.com' } }.to_json
      )
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(remote)

      get show_path, headers: auth, as: :json

      body = response.parsed_body
      expect(body['owner_pending']).to be(true)
      expect(body['conflict']).to be(false)
      expect(body['message']).to include('not yet confirmed')
      expect(body['message']).not_to include('Refreshed')
      expect(body['lead_owner']).to eq('boss@example.com')
      expect(body['lead_owner_sync_pending']).to be(true)
    end
  end
end
