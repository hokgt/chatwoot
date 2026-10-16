# frozen_string_literal: true

require 'rails_helper'

# Account-scoped list/create for the ERP Lead "Product Requirement" Link field.
# Any authenticated account agent may use it (no admin-only gate); it gates on ERP
# configuration and sanitizes every upstream failure.
RSpec.describe 'Wijaya Product Requirements API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:auth) { { api_access_token: agent.access_token.token } }
  let(:base_path) { "/api/v1/accounts/#{account.id}/wijaya/product_requirements" }

  def stub_service(instance)
    allow(Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService).to receive(:new).and_return(instance)
  end

  describe 'authorization / account scope' do
    it 'rejects an unauthenticated request' do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(true)

      get base_path, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'allows an ordinary account agent (no admin-only restriction)' do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(true)
      stub_service(instance_double(Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService, list: []))

      get base_path, headers: auth, as: :json

      expect(response).to have_http_status(:success)
    end
  end

  context 'when ERP is not configured' do
    before { allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(false) }

    it 'GET index is unprocessable and never runs the service' do
      expect(Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService).not_to receive(:new)

      get base_path, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['configured']).to be(false)
    end

    it 'POST create is unprocessable and never runs the service' do
      expect(Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService).not_to receive(:new)

      post base_path, params: { product_name: 'X', product_price: '1' }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  context 'when ERP is configured' do
    before { allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(true) }

    describe 'GET index' do
      it 'returns bounded, searchable {value, label} options (value=name, label=product_name)' do
        service = instance_double(Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService)
        expect(service).to receive(:list).with(query: 'blue', limit: nil)
                                         .and_return([{ value: 'LPR-1', label: 'Blue Shirt' }])
        stub_service(service)

        get base_path, params: { q: 'blue' }, headers: auth, as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['options']).to eq([{ 'value' => 'LPR-1', 'label' => 'Blue Shirt' }])
      end

      it 'sanitizes an upstream failure to a bad gateway (no raw ERP detail)' do
        service = instance_double(Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService)
        allow(service).to receive(:list).and_raise(Wijaya::Batteries::ErpLeadSidebar::SyncError, 'raw ERP secret')
        stub_service(service)

        get base_path, headers: auth, as: :json

        expect(response).to have_http_status(:bad_gateway)
        expect(response.parsed_body['error']).to eq('Product Requirements are currently unavailable.')
        expect(response.body).not_to include('raw ERP secret')
      end
    end

    describe 'POST create' do
      it 'passes only product_name/product_price through and returns the created record' do
        service = instance_double(Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService)
        expect(service).to receive(:create).with(product_name: 'Red Cap', product_price: '50000')
                                           .and_return(value: 'LPR-9', label: 'Red Cap', duplicate: false)
        stub_service(service)

        # An injected `name` (the ERP document id) must be ignored by strong params.
        post base_path, params: { product_name: 'Red Cap', product_price: '50000', name: 'HACK' }, headers: auth, as: :json

        expect(response).to have_http_status(:created)
        expect(response.parsed_body).to include('value' => 'LPR-9', 'label' => 'Red Cap', 'duplicate' => false)
      end

      it 'returns the existing record with a truthful message on a duplicate' do
        service = instance_double(Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService)
        allow(service).to receive(:create).and_return(value: 'LPR-1', label: 'Blue Shirt', duplicate: true)
        stub_service(service)

        post base_path, params: { product_name: 'blue shirt' }, headers: auth, as: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include('value' => 'LPR-1', 'duplicate' => true)
        expect(response.parsed_body['message']).to match(/already exists/)
      end

      it 'surfaces a local validation error as 422' do
        service = instance_double(Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService)
        allow(service).to receive(:create)
          .and_raise(Wijaya::Batteries::ErpLeadSidebar::ValidationError, 'Product Name is required')
        stub_service(service)

        post base_path, params: { product_name: '' }, headers: auth, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq('Product Name is required')
      end

      it 'sanitizes an upstream failure to a bad gateway (no raw ERP detail)' do
        service = instance_double(Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService)
        allow(service).to receive(:create).and_raise(Wijaya::Batteries::ErpLeadSidebar::SyncError, 'raw ERP secret')
        stub_service(service)

        post base_path, params: { product_name: 'Red Cap', product_price: '10' }, headers: auth, as: :json

        expect(response).to have_http_status(:bad_gateway)
        expect(response.parsed_body['error']).to eq('Could not create the Product Requirement. Please try again.')
        expect(response.body).not_to include('raw ERP secret')
      end
    end
  end
end
