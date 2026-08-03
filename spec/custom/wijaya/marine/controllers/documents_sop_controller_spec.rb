# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Marine::Documents SOP', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:assistant) { create(:marine_assistant, account: account) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  def sop_file(bytes = ("%PDF-1.4\n" + ('a' * 400)).b, filename: 'procedure.pdf', type: 'application/pdf')
    file = Tempfile.new(['req-sop', File.extname(filename)])
    file.binmode
    file.write(bytes)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, type, original_filename: filename)
  end

  def create_params(overrides = {})
    { source_kind: 'sop_document', assistant_id: assistant.id, name: 'Safety SOP', file: sop_file }.merge(overrides)
  end

  describe 'POST .../marine/documents (source_kind=sop_document)' do
    it 'rejects unauthenticated users' do
      post "/api/v1/accounts/#{account.id}/marine/documents", params: create_params
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects agents (admin-only write)' do
      post "/api/v1/accounts/#{account.id}/marine/documents",
           params: create_params, headers: agent.create_new_auth_token
      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates an SOP document in the processing state and enqueues the SOP job' do
      expect do
        post "/api/v1/accounts/#{account.id}/marine/documents",
             params: create_params, headers: admin.create_new_auth_token
      end.to have_enqueued_job(Marine::Documents::ProcessJob)

      expect(response).to have_http_status(:created)
      expect(json_response[:source_kind]).to eq('sop_document')
      expect(json_response[:status]).to eq('in_progress')
      expect(json_response[:sync_status]).to eq('syncing')
      expect(json_response[:content]).to be_nil
      expect(json_response[:external_link]).to be_nil
      expect(json_response[:primary_catalog]).to be(false)
      expect(json_response[:source_file][:content_type]).to eq('application/pdf')
      expect(json_response[:source_file].keys).to match_array(%i[filename content_type byte_size checksum])
    end

    it 'returns 422 for an oversize upload without enqueuing anything' do
      big = ("%PDF-1.4\n" + ('a' * (2 * 1024 * 1024 + 1))).b
      expect do
        post "/api/v1/accounts/#{account.id}/marine/documents",
             params: create_params(file: sop_file(big)), headers: admin.create_new_auth_token
      end.not_to have_enqueued_job(Marine::Documents::ProcessJob)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response[:i18n_key]).to eq('MARINE.DOCUMENTS.ERRORS.INVALID_FILE')
    end

    it 'returns 422 for a spoofed (type-mismatched) upload' do
      spoofed = sop_file("\x89PNG\r\n\x1A\n".b + ('a' * 50), filename: 'procedure.pdf', type: 'application/pdf')
      post "/api/v1/accounts/#{account.id}/marine/documents",
           params: create_params(file: spoofed), headers: admin.create_new_auth_token
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response[:i18n_key]).to eq('MARINE.DOCUMENTS.ERRORS.INVALID_FILE')
    end

    it 'returns 404 for an assistant in another account' do
      foreign = create(:marine_assistant, account: other_account)
      post "/api/v1/accounts/#{account.id}/marine/documents",
           params: create_params(assistant_id: foreign.id), headers: admin.create_new_auth_token
      expect(response).to have_http_status(:not_found)
    end

    it 'does not return extracted SOP text from create/show/index serialization' do
      post "/api/v1/accounts/#{account.id}/marine/documents",
           params: create_params, headers: admin.create_new_auth_token
      expect(response).to have_http_status(:created)
      id = json_response[:id]

      # Simulate a completed extraction with real DB content, then prove no endpoint
      # serializes that content.
      Marine::Document.find(id).update!(content: 'CONFIDENTIAL extracted SOP body', status: :available, sync_status: :synced)

      get "/api/v1/accounts/#{account.id}/marine/documents/#{id}", headers: admin.create_new_auth_token
      expect(response).to have_http_status(:ok)
      expect(json_response).to have_key(:content)
      expect(json_response[:content]).to be_nil
      expect(response.body).not_to include('CONFIDENTIAL')

      get "/api/v1/accounts/#{account.id}/marine/documents", params: { assistant_id: assistant.id },
                                                              headers: admin.create_new_auth_token
      expect(response.body).not_to include('CONFIDENTIAL')
      expect(json_response[:payload].map { |d| d[:content] }).to all(be_nil)
    end
  end

  describe 'POST .../marine/documents (approved nested document[source_kind]=sop_document)' do
    it 'creates an SOP document from nested document[source_file] and enqueues the SOP job' do
      expect do
        post "/api/v1/accounts/#{account.id}/marine/documents",
             params: { document: { source_kind: 'sop_document', assistant_id: assistant.id,
                                   name: 'Nested SOP', source_file: sop_file } },
             headers: admin.create_new_auth_token
      end.to have_enqueued_job(Marine::Documents::ProcessJob)

      expect(response).to have_http_status(:created)
      expect(json_response[:source_kind]).to eq('sop_document')
      expect(json_response[:name]).to eq('Nested SOP')
      expect(json_response[:sync_status]).to eq('syncing')
      expect(json_response[:source_file][:content_type]).to eq('application/pdf')
    end

    it 'rejects a spoofed nested upload with 422' do
      spoofed = sop_file("\x89PNG\r\n\x1A\n".b + ('a' * 50), filename: 'procedure.pdf', type: 'application/pdf')
      post "/api/v1/accounts/#{account.id}/marine/documents",
           params: { document: { source_kind: 'sop_document', assistant_id: assistant.id, source_file: spoofed } },
           headers: admin.create_new_auth_token
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response[:i18n_key]).to eq('MARINE.DOCUMENTS.ERRORS.INVALID_FILE')
    end
  end

  describe 'POST .../marine/documents/:id/sync' do
    it 'queues SOP reprocessing and returns 202' do
      document = create(:marine_document, :sop_document, assistant: assistant)

      expect do
        post "/api/v1/accounts/#{account.id}/marine/documents/#{document.id}/sync",
             headers: admin.create_new_auth_token
      end.to have_enqueued_job(Marine::Documents::ProcessJob)
        .with(document, document.source_file.blob.id, anything)

      expect(response).to have_http_status(:accepted)
      expect(document.reload.sync_status).to eq('syncing')
    end

    it 'rejects syncing a product catalog (never processable)' do
      document = create(:marine_document, :product_catalog, assistant: assistant)

      expect do
        post "/api/v1/accounts/#{account.id}/marine/documents/#{document.id}/sync",
             headers: admin.create_new_auth_token
      end.not_to have_enqueued_job(Marine::Documents::ProcessJob)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response[:i18n_key]).to eq('MARINE.DOCUMENTS.ERRORS.NOT_SYNCABLE')
    end

    it 'does not leak a broker error or leave the SOP document syncing when enqueue fails' do
      document = create(:marine_document, :sop_document, assistant: assistant)
      allow(Marine::Documents::ProcessJob).to receive(:perform_later).and_raise(StandardError, 'broker down')

      post "/api/v1/accounts/#{account.id}/marine/documents/#{document.id}/sync",
           headers: admin.create_new_auth_token

      expect(response).to have_http_status(:service_unavailable)
      expect(json_response[:i18n_key]).to eq('MARINE.DOCUMENTS.ERRORS.ENQUEUE_FAILED')
      expect(response.body).not_to include('broker down')
      document.reload
      expect(document.sync_status).to eq('failed')
      expect(document.last_sync_error_code).to eq('sop_enqueue_failed')
    end
  end

  describe 'internal run token is never exposed' do
    it 'omits the sync_run_token from the serialized document' do
      document = create(:marine_document, :sop_document, assistant: assistant)
      document.update!(sync_run_token: 'secret-run-token')

      get "/api/v1/accounts/#{account.id}/marine/documents/#{document.id}",
          headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(response.body).not_to include('secret-run-token')
      expect(response.body).not_to include('sync_run_token')
    end
  end

  describe 'website regression (unchanged paths)' do
    it 'still creates a website document via the nested document params' do
      expect do
        post "/api/v1/accounts/#{account.id}/marine/documents",
             params: { document: { assistant_id: assistant.id, external_link: 'https://example.com/page' } },
             headers: admin.create_new_auth_token, as: :json
      end.to change(Marine::Document.where(source_kind: 'website'), :count).by(1)
      expect(response).to have_http_status(:created)
      expect(json_response[:source_kind]).to eq('website')
    end

    it 'still routes website sync to the response builder, not the SOP job' do
      document = create(:marine_document, :website, assistant: assistant)

      expect do
        post "/api/v1/accounts/#{account.id}/marine/documents/#{document.id}/sync",
             headers: admin.create_new_auth_token
      end.to have_enqueued_job(Marine::Documents::ResponseBuilderJob)

      expect(response).to have_http_status(:accepted)
    end
  end
end
