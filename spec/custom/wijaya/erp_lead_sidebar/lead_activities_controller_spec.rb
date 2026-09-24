# frozen_string_literal: true

require 'rails_helper'

# The manual Lead Activity endpoints are nested under an existing ERP Lead draft
# (addressed by the conversation display_id). They must never create a draft and
# must gate on both configuration and a linked ERP Lead. Each read endpoint is
# independent and hits ONLY its own ERP dependency (or, for meta, none at all).
RSpec.describe 'Wijaya Lead Activities API', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:auth) { { api_access_token: agent.access_token.token } }

  let(:base_path) do
    "/api/v1/accounts/#{account.id}/wijaya/erp_lead_drafts/#{conversation.display_id}/lead_activities"
  end
  let(:meta_path) { "#{base_path}/meta" }
  let(:activity_options_path) { "#{base_path}/activity_options" }
  let(:pic_options_path) { "#{base_path}/person_in_charge_options" }

  before { create(:inbox_member, inbox: inbox, user: agent) }

  def create_draft(erp_lead_id:)
    Wijaya::ErpLeadDraft.create!(account: account, conversation: conversation, erp_lead_id: erp_lead_id)
  end

  context 'when ERP is not configured' do
    before do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(false)
    end

    it 'GET meta is unprocessable and issues no ERP request' do
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).not_to receive(:new)

      get meta_path, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['configured']).to be(false)
    end

    it 'GET activity_options is unprocessable and never runs the options service' do
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).not_to receive(:new)

      get activity_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['configured']).to be(false)
    end

    it 'GET person_in_charge_options is unprocessable and never queries the directory' do
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).not_to receive(:fetch_options)

      get pic_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
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

    it 'GET meta requires a linked lead and issues no ERP request' do
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).not_to receive(:new)

      get meta_path, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to match(/Create or link an ERP Lead/)
    end

    it 'GET activity_options requires a linked lead and does not fetch options' do
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).not_to receive(:new)

      get activity_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to match(/Create or link an ERP Lead/)
    end

    it 'GET person_in_charge_options requires a linked lead and does not query the directory' do
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).not_to receive(:fetch_options)

      get pic_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'POST create requires a linked lead and never runs the service' do
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityService).not_to receive(:new)

      post base_path, params: { submission_id: SecureRandom.uuid }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'never creates a draft row' do
      expect do
        get activity_options_path, headers: auth, as: :json
      end.not_to change(Wijaya::ErpLeadDraft, :count)
    end
  end

  context 'when ERP is configured and an ERP Lead is linked' do
    before do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(true)
      create_draft(erp_lead_id: 'LEAD-0001')
    end

    def stub_options_service(**methods)
      options_service = instance_double(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService, **methods)
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).to receive(:new).and_return(options_service)
      options_service
    end

    # --- meta ---------------------------------------------------------------

    it 'GET meta returns the default date and issues NO ERP request' do
      stub_options_service(default_date: '2026-08-10')
      # meta must touch neither the Activity Master fetch nor the User directory.
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).not_to receive(:fetch_options)

      get meta_path, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['default_date']).to eq('2026-08-10')
      expect(response.parsed_body).not_to have_key('options')
    end

    # --- activity_options ---------------------------------------------------

    it 'GET activity_options returns only the master names and queries only its own dependency' do
      stub_options_service(fetch_activity_names: %w[Call WhatsApp])
      # The Activity Master endpoint must never touch the User directory.
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).not_to receive(:fetch_options)

      get activity_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['options']).to eq(%w[Call WhatsApp])
      expect(response.parsed_body).not_to have_key('person_in_charge_options')
    end

    it 'GET activity_options returns a valid empty list as a successful load' do
      stub_options_service(fetch_activity_names: [])

      get activity_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['options']).to eq([])
    end

    it 'GET activity_options surfaces a sanitized message when the fetch fails' do
      service = instance_double(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService)
      allow(service).to receive(:fetch_activity_names)
        .and_raise(Wijaya::Batteries::ErpLeadSidebar::SyncError, 'raw ERP secret detail')
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).to receive(:new).and_return(service)

      get activity_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['error']).to eq('Lead Activity options are currently unavailable.')
      expect(response.body).not_to include('raw ERP secret detail')
    end

    it 'GET activity_options treats a malformed successful body as a bad gateway, not an empty list' do
      service = instance_double(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService)
      allow(service).to receive(:fetch_activity_names)
        .and_raise(Wijaya::Batteries::ErpLeadSidebar::MalformedResponseError, 'malformed body')
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).to receive(:new).and_return(service)

      get activity_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['error']).to eq('Lead Activity options are currently unavailable.')
    end

    # End-to-end classification through the real options service (SafeHttp stubbed):
    # a malformed upstream body must surface as a sanitized bad gateway, never a 500
    # or a misleading empty list.
    def erp_ok(body)
      http_ok = Net::HTTPOK.new('1.1', '200', 'OK')
      allow(http_ok).to receive(:body).and_return(body.to_json)
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive_messages(
        erp_base_url: 'https://erp.example.com', erp_api_key: 'key', erp_api_secret: 'secret'
      )
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(http_ok)
    end

    it 'GET activity_options maps a malformed top-level JSON array to a sanitized bad gateway' do
      erp_ok([{ 'name' => 'Call' }])

      get activity_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['error']).to eq('Lead Activity options are currently unavailable.')
    end

    it 'GET activity_options maps a malformed row to a sanitized bad gateway' do
      erp_ok('data' => [{ 'name' => 'Call' }, 'bad'])

      get activity_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['error']).to eq('Lead Activity options are currently unavailable.')
    end

    it 'GET activity_options returns a genuinely empty ERP list as a successful empty load' do
      erp_ok('data' => [])

      get activity_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['options']).to eq([])
    end

    # --- person_in_charge_options -------------------------------------------

    it 'GET person_in_charge_options returns sanitized options and queries only the directory' do
      # The PIC endpoint must never instantiate the Activity Master options service.
      expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).not_to receive(:new)
      pic = [{ value: 'agent@erp.example', label: 'Agent Example' }]
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).to receive(:fetch_options).and_return(pic)

      get pic_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['options']).to eq(
        [{ 'value' => 'agent@erp.example', 'label' => 'Agent Example' }]
      )
    end

    it 'GET person_in_charge_options returns a valid empty list as a successful load' do
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).to receive(:fetch_options).and_return([])

      get pic_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['options']).to eq([])
    end

    it 'GET person_in_charge_options surfaces a sanitized bad gateway when the directory is unavailable' do
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).to receive(:fetch_options)
        .and_raise(Wijaya::Batteries::ErpLeadSidebar::SyncError, 'raw ERP User detail')

      get pic_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['options']).to eq([])
      expect(response.body).not_to include('raw ERP User detail')
    end

    # --- create (unchanged) -------------------------------------------------

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
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityService).to receive(:new) do |params:, **|
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

    it 'allows an ordinary agent with access to this conversation to read activity options' do
      options_service = instance_double(
        Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService, fetch_activity_names: %w[Call]
      )
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).to receive(:new).and_return(options_service)

      get activity_options_path, headers: auth, as: :json

      expect(response).to have_http_status(:success)
    end

    context 'when acting as an agent without access to this conversation' do
      let(:outsider) { create(:user, account: account, role: :agent) }
      let(:outsider_auth) { { api_access_token: outsider.access_token.token } }

      it 'denies GET meta' do
        expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).not_to receive(:new)

        get meta_path, headers: outsider_auth, as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'denies GET activity_options and never fetches options' do
        expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).not_to receive(:new)

        get activity_options_path, headers: outsider_auth, as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'denies GET person_in_charge_options and never queries the directory' do
        expect(Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory).not_to receive(:fetch_options)

        get pic_options_path, headers: outsider_auth, as: :json

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
