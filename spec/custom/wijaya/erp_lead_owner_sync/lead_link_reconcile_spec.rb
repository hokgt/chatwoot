# frozen_string_literal: true

require 'rails_helper'

# Critical Case B: a conversation can be assigned to an agent BEFORE any ERP Lead exists,
# so the assignee-change seam finds no linked erp_lead_id and returns. When the existing
# erp_lead_sidebar SyncService/controller path later first sets erp_lead_id on the draft
# (create or relink), the battery LeadDraftExtensions seam reconciles the conversation's
# CURRENT committed assignee email as lead_owner via the existing OwnerSyncJob. Assignment
# alone never creates a Lead — only the later link does.
RSpec.describe 'ERP Lead owner sync — lead-link reconcile', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:agent_b) { create(:user, account: account, role: :agent, email: 'erp-user-b@example.com') }
  let(:agent_c) { create(:user, account: account, role: :agent, email: 'erp-user-c@example.com') }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:job) { Wijaya::Batteries::ErpLeadOwnerSync::OwnerSyncJob }

  def unlinked_draft
    Wijaya::ErpLeadDraft.create!(account: account, conversation: conversation, fields: {}, sync_status: 'draft')
  end

  describe 'the lead-link seam (fires with the current committed assignee)' do
    before { allow(job).to receive(:perform_later) }

    it 'enqueues the owner sync when a draft first links its ERP lead after assignment' do
      conversation.update!(assignee: agent_b) # assigned BEFORE any lead exists
      draft = unlinked_draft
      expect(job).not_to have_received(:perform_later) # assignment alone never syncs an owner

      draft.update!(erp_lead_id: 'LEAD-0001', sync_status: 'synced') # the existing SyncService linkage

      expect(job).to have_received(:perform_later).with(conversation.id, agent_b.id)
    end

    it 'does not enqueue when the linked conversation has no assignee' do
      draft = unlinked_draft

      draft.update!(erp_lead_id: 'LEAD-0001', sync_status: 'synced')

      expect(job).not_to have_received(:perform_later)
    end

    it 'enqueues on a draft created already linked (after_create_commit)' do
      conversation.update!(assignee: agent_b)

      Wijaya::ErpLeadDraft.create!(
        account: account, conversation: conversation, fields: {}, erp_lead_id: 'LEAD-0001', sync_status: 'synced'
      )

      expect(job).to have_received(:perform_later).with(conversation.id, agent_b.id)
    end

    it 'does not enqueue on an ordinary draft field update that does not link a lead' do
      conversation.update!(assignee: agent_b)
      draft = unlinked_draft

      draft.update!(fields: { 'city' => 'Jakarta' })

      expect(job).not_to have_received(:perform_later)
    end

    it 'reconciles the LATEST assignee when reassignment raced the lead link' do
      conversation.update!(assignee: agent_b)
      draft = unlinked_draft
      # Reassignment to C commits before the lead is linked; the seam must reconcile C.
      conversation.update!(assignee: agent_c)

      draft.update!(erp_lead_id: 'LEAD-0001', sync_status: 'synced')

      expect(job).to have_received(:perform_later).with(conversation.id, agent_c.id)
    end
  end

  describe 'end to end (owner becomes the assignee email after linkage)' do
    let(:requests) { [] }

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
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        allow(response).to receive(:body).and_return('{}')
        response
      end
    end

    it 'PUTs the assignee email as lead_owner once the lead links' do
      conversation.update!(assignee: agent_b)
      draft = unlinked_draft

      perform_enqueued_jobs do
        draft.update!(erp_lead_id: 'LEAD-0001', sync_status: 'synced')
      end

      expect(requests.length).to eq(1)
      expect(requests.first[:method]).to eq(:put)
      expect(requests.first[:uri].to_s).to eq('https://erp.example.com/api/resource/Lead/LEAD-0001')
      expect(JSON.parse(requests.first[:body])).to eq('lead_owner' => agent_b.email)
      expect(draft.reload.fields['lead_owner']).to eq(agent_b.email)
    end
  end

  # Runs the ACTUAL erp_lead_sidebar SyncService create path (POST-create a new Lead), not a
  # bare draft.update!, and proves: the create POST never carries an owner even when the draft
  # holds an untrusted/stale/name-mapping lead_owner; the link commits; and the post-link owner
  # job then validates the CURRENT assignee email and sends exactly one owner-only PUT.
  describe 'real SyncService create path (owner never in POST; set only post-link)' do
    let(:requests) { [] }

    def stub_erp(valid_user: true)
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive_messages(
        erp_configured?: true, erp_base_url: 'https://erp.example.com', erp_api_key: 'key', erp_api_secret: 'secret'
      )
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).to receive(:valid?).and_return(valid_user)
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, body: nil, **|
        requests << { method: method, uri: uri, body: body }
        json = case method
               when :get then '{"data":[]}'                  # no existing lead by phone -> create
               when :post then '{"data":{"name":"LEAD-0001"}}' # created lead id
               else '{}'                                      # owner PUT
               end
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        allow(response).to receive(:body).and_return(json)
        response
      end
    end

    # A draft whose stored owner is a stale value EQUAL to the current assignee email — the exact
    # shape that would make OwnerSyncService#already_synced? a false no-op if it were not sanitized
    # off the draft when the Lead first links.
    def draft_with_stale_owner(owner)
      Wijaya::ErpLeadDraft.create!(
        account: account, conversation: conversation, sync_status: 'draft',
        fields: { 'lead_owner' => owner, 'first_name' => 'Bob', 'status' => 'Lead', 'industry' => 'Garment',
                  'whatsapp_no' => '+628123' }
      )
    end

    def posts
      requests.select { |r| r[:method] == :post }
    end

    def puts_
      requests.select { |r| r[:method] == :put }
    end

    it 'omits the owner from the create POST and PUTs the current assignee email exactly once' do
      stub_erp(valid_user: true)
      conversation.update!(assignee: agent_b)
      draft = draft_with_stale_owner(agent_b.email) # stale value equal to the assignee email

      perform_enqueued_jobs do
        Wijaya::Batteries::ErpLeadSidebar::SyncService.new(draft).perform
      end

      expect(posts.length).to eq(1)
      expect(JSON.parse(posts.first[:body])).not_to have_key('lead_owner')

      # The owner PUT still happens (the stale draft owner did not cause a false no-op).
      expect(puts_.length).to eq(1)
      expect(puts_.first[:uri].to_s).to eq('https://erp.example.com/api/resource/Lead/LEAD-0001')
      expect(JSON.parse(puts_.first[:body])).to eq('lead_owner' => agent_b.email)

      draft.reload
      expect(draft.erp_lead_id).to eq('LEAD-0001')
      expect(draft.sync_status).to eq('synced')
      expect(draft.fields['lead_owner']).to eq(agent_b.email)
    end

    it 'links the Lead with no owner PUT and records a retryable failure when the ERP User is invalid' do
      stub_erp(valid_user: false)
      conversation.update!(assignee: agent_b)
      draft = draft_with_stale_owner('attacker@evil.example')

      perform_enqueued_jobs do
        Wijaya::Batteries::ErpLeadSidebar::SyncService.new(draft).perform
      end

      # The Lead was created (owner-less POST) but no owner was ever written.
      expect(posts.length).to eq(1)
      expect(JSON.parse(posts.first[:body])).not_to have_key('lead_owner')
      expect(puts_).to be_empty

      # Linkage and the Chatwoot assignment both survive; the draft is failed/retryable and
      # carries the intended assignee email (not the attacker value, not a prior owner).
      draft.reload
      expect(draft.erp_lead_id).to eq('LEAD-0001')
      expect(draft.sync_status).to eq('failed')
      expect(draft.last_error).to eq('ERPNext lead owner sync failed')
      expect(draft.fields['lead_owner']).to eq(agent_b.email)
      expect(conversation.reload.assignee_id).to eq(agent_b.id)
    end
  end
end
