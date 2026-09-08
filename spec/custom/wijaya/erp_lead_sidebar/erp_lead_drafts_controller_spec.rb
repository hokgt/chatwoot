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
  end
end
