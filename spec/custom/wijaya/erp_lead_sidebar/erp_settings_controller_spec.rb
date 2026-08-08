# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Wijaya ERP Settings API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  let(:base_path) { "/api/v1/accounts/#{account.id}/wijaya/erp_setting" }

  def json
    response.parsed_body
  end

  describe 'GET show' do
    it 'rejects an unauthenticated request' do
      get base_path, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects an agent' do
      get base_path, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    context 'with a saved settings row' do
      before do
        Wijaya::ErpSetting.create!(
          account: account,
          host: 'https://erp.example.com',
          api_key: 'secret-key',
          api_secret: 'secret-secret'
        )
      end

      it 'returns presence/source metadata and never the raw credentials' do
        get base_path, headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(json['host']).to eq('https://erp.example.com')
        expect(json['host_source']).to eq('account')
        expect(json['api_key_present']).to be(true)
        expect(json['api_key_source']).to eq('account')
        expect(json['api_secret_present']).to be(true)
        expect(json['configured']).to be(true)
        expect(response.body).not_to include('secret-key')
        expect(response.body).not_to include('secret-secret')
      end
    end
  end

  describe 'PUT update' do
    it 'rejects an agent' do
      put base_path,
          params: { erp_setting: { host: 'https://erp.example.com' } },
          headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'persists host, key and secret and echoes no raw credential' do
      put base_path,
          params: { erp_setting: { host: 'https://erp.example.com', api_key: 'k-123', api_secret: 's-456' } },
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      setting = Wijaya::ErpSetting.find_by(account_id: account.id)
      expect(setting.host).to eq('https://erp.example.com')
      expect(setting.api_key).to eq('k-123')
      expect(setting.api_secret).to eq('s-456')
      expect(response.body).not_to include('k-123')
      expect(response.body).not_to include('s-456')
    end

    it 'preserves the stored credentials when the inputs are blank' do
      Wijaya::ErpSetting.create!(
        account: account, host: 'https://erp.example.com', api_key: 'keep-key', api_secret: 'keep-secret'
      )

      put base_path,
          params: { erp_setting: { host: 'https://erp2.example.com', api_key: '', api_secret: '' } },
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      setting = Wijaya::ErpSetting.find_by(account_id: account.id)
      expect(setting.host).to eq('https://erp2.example.com')
      expect(setting.api_key).to eq('keep-key')
      expect(setting.api_secret).to eq('keep-secret')
    end

    it 'migrates inherited ENV credentials into encrypted account storage on first save' do
      with_modified_env(WIJAYA_ERP_API_KEY: 'env-key-to-migrate', WIJAYA_ERP_API_SECRET: 'env-secret-to-migrate') do
        put base_path,
            params: { erp_setting: { host: 'https://erp.example.com' } },
            headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        setting = Wijaya::ErpSetting.find_by!(account_id: account.id)
        expect(setting.api_key).to eq('env-key-to-migrate')
        expect(setting.api_secret).to eq('env-secret-to-migrate')
        expect(response.body).not_to include('env-key-to-migrate', 'env-secret-to-migrate')
      end
    end

    it 'returns a validation error for an invalid host' do
      put base_path,
          params: { erp_setting: { host: 'http://public.example.com' } },
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to include('HTTPS')
    end
  end

  describe 'POST test' do
    it 'rejects an agent' do
      post "#{base_path}/test",
           params: { erp_setting: { host: 'https://erp.example.com', api_key: 'k', api_secret: 's' } },
           headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'delegates to the connection test service and returns its sanitized result' do
      service = instance_double(
        Wijaya::Batteries::ErpLeadSidebar::ConnectionTestService,
        call: { ok: true, message: 'Connected to ERPNext successfully.', error: nil }
      )
      allow(Wijaya::Batteries::ErpLeadSidebar::ConnectionTestService).to receive(:new).and_return(service)

      post "#{base_path}/test",
           params: { erp_setting: { host: 'https://erp.example.com', api_key: 'k', api_secret: 's' } },
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json['ok']).to be(true)
    end
  end
end
