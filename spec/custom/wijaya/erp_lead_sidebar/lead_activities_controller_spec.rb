# frozen_string_literal: true

require 'rails_helper'

# The manual Lead Activity endpoints are nested under an existing ERP Lead draft
# (addressed by the conversation display_id). They must never create a draft and
# must gate on both configuration and a linked ERP Lead.
RSpec.describe 'Wijaya Lead Activities API', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:auth) { { api_access_token: agent.access_token.token } }

  let(:base_path) do
    "/api/v1/accounts/#{account.id}/wijaya/erp_lead_drafts/#{conversation.display_id}/lead_activities"
  end
  let(:options_path) { "#{base_path}/options" }

  before { create(:inbox_member, inbox: inbox, user: agent) }

  def create_draft(erp_lead_id:)
    Wijaya::ErpLeadDraft.create!(account: account, conversation: conversation, erp_lead_id: erp_lead_id)
  end

  context 'when ERP is not configured' do
    before do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(false)
    end

    it 'GET options is unprocessable and issues no ERP request' do
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).not_to receive(:new)

      get options_path, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['configured']).to be(false)
    end

    it 'POST create is unprocessable and never runs the service' do
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityService).not_to receive(:new)

      post base_path, params: { submission_id: SecureRandom.uuid }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  context 'when ERP is configured but no ERP Lead is linked' do
    before do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(true)
    end

    it 'GET options requires a linked lead and does not fetch options' do
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).not_to receive(:new)

      get options_path, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to match(/Create or link an ERP Lead/)
    end

    it 'POST create requires a linked lead and never runs the service' do
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityService).not_to receive(:new)

      post base_path, params: { submission_id: SecureRandom.uuid }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'never creates a draft row' do
      expect do
        get options_path, headers: auth, as: :json
      end.not_to change(Wijaya::ErpLeadDraft, :count)
    end
  end

  context 'when ERP is configured and an ERP Lead is linked' do
    before do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(true)
      create_draft(erp_lead_id: 'LEAD-0001')
    end

    def stub_options_service(fetch_names: %w[Call WhatsApp], default_date: '2026-08-10')
      options_service = instance_double(
        Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService,
        fetch_names: fetch_names, default_date: default_date
      )
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).to receive(:new).and_return(options_service)
    end

    it 'GET options returns the master names, default date, and sanitized PIC options' do
      stub_options_service
      pic = [{ value: 'agent@erp.example', label: 'Agent Example' }]
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).to receive(:fetch_options).and_return(pic)

      get options_path, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['options']).to eq(%w[Call WhatsApp])
      expect(response.parsed_body['default_date']).to eq('2026-08-10')
      expect(response.parsed_body['person_in_charge_options']).to eq(
        [{ 'value' => 'agent@erp.example', 'label' => 'Agent Example' }]
      )
      expect(response.parsed_body['person_in_charge_available']).to be(true)
    end

    it 'GET options degrades to an empty, optional PIC list when the User directory is unavailable' do
      stub_options_service
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).to receive(:fetch_options)
        .and_raise(Wijaya::Batteries::ErpLeadSidebar::SyncError, 'raw ERP User detail')

      get options_path, headers: auth, as: :json

      # The (valid) Lead Activity options survive; only PIC degrades.
      expect(response).to have_http_status(:success)
      expect(response.parsed_body['options']).to eq(%w[Call WhatsApp])
      expect(response.parsed_body['person_in_charge_options']).to eq([])
      expect(response.parsed_body['person_in_charge_available']).to be(false)
      expect(response.body).not_to include('raw ERP User detail')
    end

    it 'GET options surfaces a sanitized message when the fetch fails' do
      options_service = instance_double(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService)
      allow(options_service).to receive(:fetch_names)
        .and_raise(Wijaya::Batteries::ErpLeadSidebar::SyncError, 'raw ERP secret detail')
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).to receive(:new).and_return(options_service)

      get options_path, headers: auth, as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['error']).to eq('Lead Activity options are currently unavailable.')
      expect(response.body).not_to include('raw ERP secret detail')
    end

    it 'POST create renders the service result body and status' do
      result = Wijaya::Batteries::ErpLeadSidebar::LeadActivityService::Result.new(
        status: 'success', http_status: :ok, body: { status: 'success', message: 'Lead Activity added successfully.' }
      )
      service = instance_double(Wijaya::Batteries::ErpLeadSidebar::LeadActivityService, perform: result)
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityService).to receive(:new).and_return(service)

      post base_path, params: { submission_id: SecureRandom.uuid, date: '2026-08-10', lead_activity: 'Call' },
                      headers: auth, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Lead Activity added successfully.')
    end

    it 'excludes structural keys from the params handed to the service' do
      captured = nil
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityService).to receive(:new) do |draft:, agent:, params:|
        captured = params
        instance_double(
          Wijaya::Batteries::ErpLeadSidebar::LeadActivityService,
          perform: Wijaya::Batteries::ErpLeadSidebar::LeadActivityService::Result.new(
            status: 'success', http_status: :ok, body: { status: 'success' }
          )
        )
      end

      post base_path,
           params: { submission_id: SecureRandom.uuid, date: '2026-08-10', lead_activity: 'Call',
                     doctype: 'Sales Order', parent: 'HACK', parenttype: 'Lead', parentfield: 'x',
                     person_in_charge: 'agent@erp.example' },
           headers: auth, as: :json

      # Structural keys are never handed to the service (parent is server-derived).
      expect(captured.keys).not_to include('doctype', 'parent', 'parenttype', 'parentfield')
      # person_in_charge is the agent's manual choice: permitted, but still
      # exact-revalidated by the service before it can reach ERP.
      expect(captured.keys).to include('submission_id', 'date', 'lead_activity', 'person_in_charge')
      expect(captured['person_in_charge']).to eq('agent@erp.example')
    end
  end

  context 'with conversation authorization' do
    before do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(true)
      create_draft(erp_lead_id: 'LEAD-0001')
    end

    it 'allows an ordinary agent with access to this conversation to read options' do
      options_service = instance_double(
        Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService,
        fetch_names: %w[Call], default_date: '2026-08-10'
      )
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).to receive(:new).and_return(options_service)
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).to receive(:fetch_options).and_return([])

      get options_path, headers: auth, as: :json

      expect(response).to have_http_status(:success)
    end

    context 'when acting as an agent without access to this conversation' do
      let(:outsider) { create(:user, account: account, role: :agent) }
      let(:outsider_auth) { { api_access_token: outsider.access_token.token } }

      it 'denies GET options and never fetches options' do
        expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).not_to receive(:new)

        get options_path, headers: outsider_auth, as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'denies POST create and never runs the service' do
        expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityService).not_to receive(:new)

        post base_path, params: { submission_id: SecureRandom.uuid }, headers: outsider_auth, as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
