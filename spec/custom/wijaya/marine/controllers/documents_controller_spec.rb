# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Marine::Documents', type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:assistant) { create(:marine_assistant, account: account) }
  let(:family_code) { 'FAM-001' }

  # Request specs stub the external product-family repository so nothing ever hits
  # the canonical Marine catalog DB.
  let(:repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  def multipart_file(bytes = ("%PDF-1.4\n" + ('a' * 400)).b, filename: 'catalog.pdf', type: 'application/pdf')
    file = Tempfile.new(['req-catalog', File.extname(filename)])
    file.binmode
    file.write(bytes)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, type, original_filename: filename)
  end

  before do
    allow(Marine::Catalog::ProductFamilyRepository).to receive(:new).and_return(repository)
    allow(repository).to receive(:exists?).with(family_code).and_return(true)
    allow(repository).to receive(:search).and_return([{ code: family_code, name: 'Family One' }])
  end

  describe 'GET .../marine/documents/product_families' do
    it 'rejects unauthenticated users' do
      get "/api/v1/accounts/#{account.id}/marine/documents/product_families"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns a bounded, sanitized family list for an agent (read allowed)' do
      get "/api/v1/accounts/#{account.id}/marine/documents/product_families",
          params: { query: 'fam', limit: 5 }, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:payload]).to eq([{ code: family_code, name: 'Family One' }])
      expect(repository).to have_received(:search).with(query: 'fam', limit: 5)
    end

    it 'returns 503 when the catalog is unavailable' do
      allow(repository).to receive(:search).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)
      get "/api/v1/accounts/#{account.id}/marine/documents/product_families",
          headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:service_unavailable)
      expect(json_response[:i18n_key]).to eq('MARINE.DOCUMENTS.ERRORS.CATALOG_UNAVAILABLE')
    end
  end

  describe 'POST .../marine/documents/product_catalog' do
    let(:params) { { assistant_id: assistant.id, product_family_code: family_code, file: multipart_file } }

    it 'rejects unauthenticated users' do
      post "/api/v1/accounts/#{account.id}/marine/documents/product_catalog", params: params
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects agents (admin-only write)' do
      post "/api/v1/accounts/#{account.id}/marine/documents/product_catalog",
           params: params, headers: agent.create_new_auth_token
      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates a primary catalog for an administrator' do
      post "/api/v1/accounts/#{account.id}/marine/documents/product_catalog",
           params: params, headers: admin.create_new_auth_token

      expect(response).to have_http_status(:created)
      expect(json_response[:source_kind]).to eq('product_catalog')
      expect(json_response[:product_family_code]).to eq(family_code)
      expect(json_response[:primary_catalog]).to be(true)
      expect(json_response[:source_file][:content_type]).to eq('application/pdf')
      # File metadata only — no content checksum, download/signed URL, or storage key.
      expect(json_response[:source_file].keys).to match_array(%i[filename content_type byte_size])
      expect(json_response[:source_file]).not_to have_key(:checksum)
      expect(json_response[:source_file]).not_to have_key(:download_url)
    end

    it 'returns 409 on a duplicate without explicit replacement' do
      post "/api/v1/accounts/#{account.id}/marine/documents/product_catalog",
           params: params, headers: admin.create_new_auth_token
      post "/api/v1/accounts/#{account.id}/marine/documents/product_catalog",
           params: { assistant_id: assistant.id, product_family_code: family_code, file: multipart_file },
           headers: admin.create_new_auth_token

      expect(response).to have_http_status(:conflict)
      expect(json_response[:i18n_key]).to eq('MARINE.DOCUMENTS.ERRORS.PRIMARY_CONFLICT')
    end

    it 'replaces on an explicit replace request' do
      post "/api/v1/accounts/#{account.id}/marine/documents/product_catalog",
           params: params, headers: admin.create_new_auth_token
      post "/api/v1/accounts/#{account.id}/marine/documents/product_catalog",
           params: { assistant_id: assistant.id, product_family_code: family_code, file: multipart_file, replace: true },
           headers: admin.create_new_auth_token

      expect(response).to have_http_status(:created)
      expect(assistant.documents.where(source_kind: 'product_catalog', primary_catalog: true).count).to eq(1)
    end

    it 'returns 422 for an unknown product family' do
      allow(repository).to receive(:exists?).with(family_code).and_return(false)
      post "/api/v1/accounts/#{account.id}/marine/documents/product_catalog",
           params: params, headers: admin.create_new_auth_token
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response[:i18n_key]).to eq('MARINE.DOCUMENTS.ERRORS.UNKNOWN_FAMILY')
    end

    it 'returns 422 for an invalid (spoofed) upload' do
      spoofed = multipart_file("\x89PNG\r\n\x1A\n".b + ('a' * 50), filename: 'catalog.pdf', type: 'application/pdf')
      post "/api/v1/accounts/#{account.id}/marine/documents/product_catalog",
           params: { assistant_id: assistant.id, product_family_code: family_code, file: spoofed },
           headers: admin.create_new_auth_token
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response[:i18n_key]).to eq('MARINE.DOCUMENTS.ERRORS.INVALID_FILE')
    end

    it 'returns 404 for an assistant in another account' do
      foreign = create(:marine_assistant, account: other_account)
      post "/api/v1/accounts/#{account.id}/marine/documents/product_catalog",
           params: { assistant_id: foreign.id, product_family_code: family_code, file: multipart_file },
           headers: admin.create_new_auth_token
      expect(response).to have_http_status(:not_found)
    end

    it 'returns 503 when the catalog is unavailable' do
      allow(repository).to receive(:exists?).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)
      post "/api/v1/accounts/#{account.id}/marine/documents/product_catalog",
           params: params, headers: admin.create_new_auth_token
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe 'existing website behavior is unchanged' do
    let!(:website_document) { create(:marine_document, :website, assistant: assistant) }

    it 'lists website documents with source-aware serialization' do
      get "/api/v1/accounts/#{account.id}/marine/documents",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      payload = json_response[:payload]
      expect(payload.first[:source_kind]).to eq('website')
      expect(payload.first[:source_file]).to be_nil
    end

    it 'creates a website document without a file or family' do
      expect do
        post "/api/v1/accounts/#{account.id}/marine/documents",
             params: { document: { assistant_id: assistant.id, external_link: 'https://example.com/new-page' } },
             headers: admin.create_new_auth_token, as: :json
      end.to change(Marine::Document.where(source_kind: 'website'), :count).by(1)
      expect(response).to have_http_status(:created)
      expect(json_response[:source_kind]).to eq('website')
    end
  end
end
