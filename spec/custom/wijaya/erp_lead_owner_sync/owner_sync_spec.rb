# frozen_string_literal: true

require 'rails_helper'

# Unit contract for the ERP Lead owner sync job/service. Outbound ERP is mocked
# throughout (SafeHttp + the User validator + Config); no real ERP is contacted and no
# persistent ERP record is created. The ERP owner is the committed assignee's Chatwoot
# email — never a name, never a substituted user, and never gated by an id map.
RSpec.describe 'ERP Lead owner sync', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:agent_b) { create(:user, account: account, role: :agent, email: 'erp-user-b@example.com') }
  let(:agent_c) { create(:user, account: account, role: :agent, email: 'erp-user-c@example.com') }
  let(:erp_user) { agent_b.email }
  let(:requests) { [] }
  let(:put_ok) { true }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  def draft_with(overrides = {})
    Wijaya::ErpLeadDraft.create!(
      { account: account, conversation: conversation, fields: {}, erp_lead_id: 'LEAD-0001', sync_status: 'draft' }.merge(overrides)
    )
  end

  before do
    allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive_messages(
      erp_configured?: true,
      erp_base_url: 'https://erp.example.com',
      erp_api_key: 'key',
      erp_api_secret: 'secret'
    )
    allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).to receive(:valid?).and_return(true)

    allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, body: nil, **|
      requests << { method: method, uri: uri, body: body }
      status = put_ok ? %w[200 OK] : %w[500 Error]
      klass = put_ok ? Net::HTTPOK : Net::HTTPInternalServerError
      response = klass.new('1.1', status[0], status[1])
      allow(response).to receive(:body).and_return('{}')
      response
    end
  end

  def run_job(expected_assignee_id: agent_b.id)
    Wijaya::Batteries::ErpLeadOwnerSync::OwnerSyncJob.perform_now(conversation.id, expected_assignee_id)
  end

  # Set the committed assignee without firing the after_update_commit seam, so each
  # job/service example drives the job explicitly rather than via the enqueue path.
  def assign_committed(user_id)
    conversation.update_column(:assignee_id, user_id) # rubocop:disable Rails/SkipsModelValidations
  end

  describe 'successful committed nil -> Agent B assignment' do
    it 'PUTs only the owner (the assignee email) to the linked lead and marks the draft synced' do
      draft = draft_with
      assign_committed(agent_b.id)

      run_job

      expect(requests.length).to eq(1)
      expect(requests.first[:method]).to eq(:put)
      expect(requests.first[:uri].to_s).to eq('https://erp.example.com/api/resource/Lead/LEAD-0001')
      expect(JSON.parse(requests.first[:body])).to eq('lead_owner' => agent_b.email)

      draft.reload
      expect(draft.sync_status).to eq('synced')
      expect(draft.fields['lead_owner']).to eq(agent_b.email)
      expect(draft.last_error).to be_nil
    end
  end

  describe 'owner resolution is the assignee email' do
    it 'sends the assignee email and never the agent display name' do
      draft_with
      # A distinct, non-email display name that must never leak into the ERP owner value.
      agent_b.update!(name: 'Budi The Agent')
      assign_committed(agent_b.id)

      run_job

      expect(JSON.parse(requests.first[:body])).to eq('lead_owner' => agent_b.email)
      expect(requests.first[:body]).not_to include(agent_b.name)
    end

    it 'sends nothing but the assignee email as the owner (no id/name mapping exists)' do
      # There is no id/name map any more: resolution is email-only, so the PUT happens purely
      # from the assignee email with nothing else consulted.
      draft_with
      assign_committed(agent_b.id)

      run_job

      expect(requests.length).to eq(1)
      expect(JSON.parse(requests.first[:body])).to eq('lead_owner' => agent_b.email)
    end
  end

  describe 'no linked draft / blank erp_lead_id' do
    it 'skips without any ERP call and creates no draft' do
      assign_committed(agent_b.id)

      run_job

      expect(requests).to be_empty
      expect(Wijaya::ErpLeadDraft.where(conversation_id: conversation.id)).to be_empty
    end

    it 'skips a draft that has no erp_lead_id yet (never creates an ERP lead)' do
      draft = draft_with(erp_lead_id: nil)
      assign_committed(agent_b.id)

      run_job

      expect(requests).to be_empty
      expect(draft.reload.sync_status).to eq('draft')
    end
  end

  describe 'invalid ERP User' do
    it 'keeps the assignment, issues no ERP PUT, and records a retryable failure with the intended email' do
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).to receive(:valid?).and_return(false)
      draft = draft_with(fields: { 'lead_owner' => 'previous-owner@example.com' }, sync_status: 'synced')
      assign_committed(agent_b.id)

      run_job

      expect(requests).to be_empty
      expect(conversation.reload.assignee_id).to eq(agent_b.id)
      draft.reload
      expect(draft.sync_status).to eq('failed')
      expect(draft.last_error).to eq('ERPNext lead owner sync failed')
      expect(draft.fields['lead_owner']).to eq(agent_b.email)
    end
  end

  describe 'stale job after a rapid B -> C reassignment' do
    it 'does not push B once the conversation has moved to C' do
      draft_with
      assign_committed(agent_c.id)

      run_job(expected_assignee_id: agent_b.id)

      expect(requests).to be_empty
    end
  end

  describe 'duplicate / repeated processing' do
    it 'issues no second ERP PUT once already synced to the same owner' do
      draft_with
      assign_committed(agent_b.id)

      run_job
      expect(requests.length).to eq(1)

      run_job
      expect(requests.length).to eq(1)
    end

    it 'still retries when the draft is in a failed state' do
      draft_with(fields: { 'lead_owner' => erp_user }, sync_status: 'failed')
      assign_committed(agent_b.id)

      run_job

      expect(requests.length).to eq(1)
    end
  end

  describe 'ERP failure' do
    let(:put_ok) { false }

    it 'keeps assignee B committed and records the intended owner B in the failed draft for retry' do
      draft = draft_with(fields: { 'lead_owner' => 'previous-owner-a@example.com' }, sync_status: 'synced')
      assign_committed(agent_b.id)

      run_job

      expect(conversation.reload.assignee_id).to eq(agent_b.id)
      draft.reload
      expect(draft.sync_status).to eq('failed')
      expect(draft.last_error).to eq('ERPNext lead owner sync failed')
      # The draft-driven sidebar retry must resend the intended new owner B, not the
      # previous owner A that was there before the failed sync.
      expect(draft.fields['lead_owner']).to eq(agent_b.email)
    end
  end

  describe 'ERP User-directory validation outage' do
    it 'marks the draft failed with the intended owner B (same as a PUT failure)' do
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory)
        .to receive(:valid?).and_raise(Wijaya::Batteries::ErpLeadSidebar::SyncError, 'directory outage')
      draft = draft_with(fields: { 'lead_owner' => 'previous-owner-a@example.com' }, sync_status: 'synced')
      assign_committed(agent_b.id)

      run_job

      expect(requests).to be_empty
      expect(conversation.reload.assignee_id).to eq(agent_b.id)
      draft.reload
      expect(draft.sync_status).to eq('failed')
      expect(draft.last_error).to eq('ERPNext lead owner sync failed')
      expect(draft.fields['lead_owner']).to eq(agent_b.email)
    end

    it 'does not overwrite the draft owner once the conversation has moved on to C' do
      draft = draft_with(fields: { 'lead_owner' => 'previous-owner-a@example.com' }, sync_status: 'synced')
      assign_committed(agent_b.id)

      # Deterministically model the B -> C reassignment committing before the B job
      # persists its failure: the directory-outage seam raises SyncError, and as it
      # does the conversation is already committed to C. The failure re-check under
      # the row lock must then decline to write, preserving the prior owner.
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).to receive(:valid?) do
        assign_committed(agent_c.id)
        raise Wijaya::Batteries::ErpLeadSidebar::SyncError, 'directory outage'
      end

      run_job(expected_assignee_id: agent_b.id)

      draft.reload
      expect(draft.fields['lead_owner']).to eq('previous-owner-a@example.com')
      expect(draft.sync_status).to eq('synced')
    end
  end

  describe 'unconfigured account' do
    it 'skips without any ERP call and leaves the draft untouched' do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(false)
      draft = draft_with
      assign_committed(agent_b.id)

      run_job

      expect(requests).to be_empty
      expect(draft.reload.sync_status).to eq('draft')
    end
  end
end
