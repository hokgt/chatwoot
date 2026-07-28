# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Marine::Provisioning', type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  # Installation-wide provisioning requires a Chatwoot SuperAdmin who also holds an
  # administrator membership in the current account.
  let(:super_admin) { create(:super_admin) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  before { create(:account_user, account: account, user: super_admin, role: :administrator) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/marine/provisioning' do
    it 'rejects unauthenticated users' do
      get "/api/v1/accounts/#{account.id}/marine/provisioning"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects agents (backend authorization, not just frontend gating)' do
      get "/api/v1/accounts/#{account.id}/marine/provisioning",
          headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a regular account administrator who is not a SuperAdmin' do
      get "/api/v1/accounts/#{account.id}/marine/provisioning",
          headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a SuperAdmin who is an administrator only in another account' do
      other_super_admin = create(:super_admin)
      create(:account_user, account: other_account, user: other_super_admin, role: :administrator)

      get "/api/v1/accounts/#{account.id}/marine/provisioning",
          headers: other_super_admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns non-secret status for a SuperAdmin administrator without touching PostgreSQL' do
      get "/api/v1/accounts/#{account.id}/marine/provisioning",
          headers: super_admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:status]).to eq('not_provisioned')
      expect(json_response).to have_key(:provisioning_configured)
    end

    it 'sets no-store on the GET status response (secret hygiene on every response)' do
      get "/api/v1/accounts/#{account.id}/marine/provisioning",
          headers: super_admin.create_new_auth_token, as: :json

      expect(response.headers['Cache-Control']).to include('no-store')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/provisioning' do
    let(:details) do
      { host: 'db', port: 5432, database_name: 'marine_erp', login_username: 'marine_app', ssl_mode: 'prefer' }
    end

    it 'rejects agents' do
      post "/api/v1/accounts/#{account.id}/marine/provisioning",
           params: { provisioning: { database_name: 'marine_erp', login_username: 'marine_app', password: 'a-strong-password-123' } },
           headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a regular account administrator who is not a SuperAdmin' do
      post "/api/v1/accounts/#{account.id}/marine/provisioning",
           params: { provisioning: { database_name: 'marine_erp', login_username: 'marine_app', password: 'a-strong-password-123' } },
           headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'delegates to the provision service and never echoes the password' do
      service = instance_double(Marine::Provisioning::ProvisionService, call: details)
      allow(Marine::Provisioning::ProvisionService).to receive(:new).and_return(service)

      post "/api/v1/accounts/#{account.id}/marine/provisioning",
           params: { provisioning: { database_name: 'marine_erp', login_username: 'marine_app', password: 'a-strong-password-123' } },
           headers: super_admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:created)
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(json_response[:credentials][:login_username]).to eq('marine_app')
      expect(response.body).not_to include('a-strong-password-123')
      expect(Marine::Provisioning::ProvisionService).to have_received(:new).with(
        hash_including(database_name: 'marine_erp', login_username: 'marine_app', password: 'a-strong-password-123')
      )
    end

    it 'renders a sanitized error without raw PG details' do
      service = instance_double(Marine::Provisioning::ProvisionService)
      allow(service).to receive(:call).and_raise(Marine::Provisioning::Errors::AlreadyProvisionedError)
      allow(Marine::Provisioning::ProvisionService).to receive(:new).and_return(service)

      post "/api/v1/accounts/#{account.id}/marine/provisioning",
           params: { provisioning: { database_name: 'marine_erp', login_username: 'marine_app', password: 'a-strong-password-123' } },
           headers: super_admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:conflict)
      expect(json_response[:i18n_key]).to eq('PROVISIONING.ERRORS.ALREADY_PROVISIONED')
    end
  end

  describe 'privilege endpoints' do
    it 'downgrades via the privilege service (SuperAdmin only)' do
      service = instance_double(Marine::Provisioning::PrivilegeService, downgrade_to_writer!: { 'privilege_level' => 'writer' })
      allow(Marine::Provisioning::PrivilegeService).to receive(:new).and_return(service)

      post "/api/v1/accounts/#{account.id}/marine/provisioning/downgrade",
           headers: super_admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(service).to have_received(:downgrade_to_writer!)
    end

    it 'rejects agents on revoke_all' do
      post "/api/v1/accounts/#{account.id}/marine/provisioning/revoke_all",
           headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a regular account administrator on revoke_all' do
      post "/api/v1/accounts/#{account.id}/marine/provisioning/revoke_all",
           headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns the privilege matrix via the catalog service' do
      matrix = { login_username: 'marine_app', role: { can_login: true } }
      service = instance_double(Marine::Provisioning::CatalogService, call: matrix)
      allow(Marine::Provisioning::CatalogService).to receive(:new).and_return(service)

      get "/api/v1/accounts/#{account.id}/marine/provisioning/privileges",
          headers: super_admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:login_username]).to eq('marine_app')
    end
  end
end
