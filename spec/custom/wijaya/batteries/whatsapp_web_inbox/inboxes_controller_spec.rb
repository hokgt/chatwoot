# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Wijaya WhatsApp Web Inboxes API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:base_path) { "/api/v1/accounts/#{account.id}/wijaya/whatsapp_web/inboxes" }
  let(:record_klass) { Wijaya::Batteries::WhatsappWebInbox::Record }
  let(:client_klass) { Wijaya::Batteries::WhatsappWebInbox::ConnectorClient }
  let(:job_klass) { Wijaya::Batteries::WhatsappWebInbox::ProvisionJob }
  let(:client) { instance_double(client_klass) }
  let(:env) do
    {
      'WHATSAPP_WEB_CONNECTOR_URL' => 'http://wa-connector:3000',
      'WHATSAPP_WEB_CONNECTOR_HMAC_SECRET' => 'svc',
      'FRONTEND_URL' => 'https://chat.example.com'
    }
  end

  def json
    response.parsed_body
  end

  def mapping_for(target_account, session_id: 'sess-1', status: 'connected')
    channel = target_account.api_channels.create!(hmac_mandatory: true,
                                                  additional_attributes: { 'wijaya_provider' => 'whatsapp_web' })
    inbox = target_account.inboxes.create!(name: 'WA', channel: channel)
    record_klass.create!(account: target_account, inbox: inbox, request_token: SecureRandom.uuid,
                         connector_session_id: session_id, provisioning_state: 'provisioned', status: status)
  end

  describe 'authorization' do
    it 'rejects an unauthenticated request' do
      post base_path, params: { name: 'WA', request_token: 't', acknowledged: true }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a non-admin agent' do
      with_modified_env(env) do
        post base_path, headers: agent.create_new_auth_token,
                        params: { name: 'WA', request_token: 't', acknowledged: true }, as: :json
      end
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'POST create' do
    around { |example| with_modified_env(env) { example.run } }
    before { allow(job_klass).to receive(:perform_later) }

    it 'requires the risk acknowledgement' do
      post base_path, headers: admin.create_new_auth_token,
                      params: { name: 'WA', request_token: 't', acknowledged: false }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to eq('acknowledgement_required')
    end

    it 'requires a name' do
      post base_path, headers: admin.create_new_auth_token,
                      params: { name: '', request_token: 't', acknowledged: true }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to eq('name_required')
    end

    it 'creates the inbox and returns a safe DTO without any secret' do
      post base_path, headers: admin.create_new_auth_token,
                      params: { name: 'Sales WA', request_token: 'tok-1', acknowledged: true }, as: :json
      expect(response).to have_http_status(:created)
      expect(json['provisioning_state']).to eq('pending')
      expect(json['inbox_id']).to be_present

      channel = Inbox.find(json['inbox_id']).channel
      expect(response.body).not_to include(channel.secret)
      expect(response.body).not_to include(channel.hmac_token)
      expect(job_klass).to have_received(:perform_later)
    end

    it 'reuses the mapping for a duplicate request token (idempotent, bypasses the rate limit)' do
      2.times do
        post base_path, headers: admin.create_new_auth_token,
                        params: { name: 'WA', request_token: 'dup', acknowledged: true }, as: :json
        expect(response).to have_http_status(:created)
      end
      expect(account.inboxes.count).to eq(1)
    end

    it 'rate-limits a second distinct create from the same admin and allocates no new rows' do
      post base_path, headers: admin.create_new_auth_token,
                      params: { name: 'WA one', request_token: 'tok-a', acknowledged: true }, as: :json
      expect(response).to have_http_status(:created)

      post base_path, headers: admin.create_new_auth_token,
                      params: { name: 'WA two', request_token: 'tok-b', acknowledged: true }, as: :json
      expect(response).to have_http_status(:too_many_requests)
      expect(json['error']).to eq('rate_limited')
      expect(account.inboxes.count).to eq(1)
      expect(record_klass.count).to eq(1)
    end

    it 'fails closed with 503 when the connector env is absent' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_HMAC_SECRET' => nil) do
        post base_path, headers: admin.create_new_auth_token,
                        params: { name: 'WA', request_token: 't', acknowledged: true }, as: :json
      end
      expect(response).to have_http_status(:service_unavailable)
      expect(json['error']).to eq('connector_unavailable')
    end
  end

  describe 'cross-account isolation' do
    around { |example| with_modified_env(env) { example.run } }

    it 'returns 404 for an inbox that belongs to another account' do
      other = mapping_for(create(:account))
      get "#{base_path}/#{other.inbox_id}", headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET show (status)' do
    around { |example| with_modified_env(env) { example.run } }
    before { allow(client_klass).to receive(:new).and_return(client) }

    it 'returns a safe DTO with the refreshed status and masked identity' do
      record = mapping_for(account)
      allow(client).to receive(:get_session)
        .and_return('id' => 'sess-1', 'status' => 'connected', 'waJid' => '6281234567890@s.whatsapp.net')

      get "#{base_path}/#{record.inbox_id}", headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
      expect(json['status']).to eq('connected')
      expect(json['connector_available']).to be(true)
      expect(json['wa_jid_masked']).to eq('••••7890')
      expect(response.body).not_to include('6281234567890')
    end

    it 'degrades to connector_available:false instead of crashing when the connector errors' do
      record = mapping_for(account)
      allow(client).to receive(:get_session).and_raise(client_klass::ConnectorUnavailable)

      get "#{base_path}/#{record.inbox_id}", headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
      expect(json['connector_available']).to be(false)
    end
  end

  describe 'GET qr' do
    around { |example| with_modified_env(env) { example.run } }
    before { allow(client_klass).to receive(:new).and_return(client) }

    it 'proxies only the data URL and never the raw QR string' do
      record = mapping_for(account, status: 'waiting_for_qr')
      allow(client).to receive(:qr)
        .and_return('available' => true, 'data_url' => 'data:image/png;base64,AAAA', 'raw_qr' => 'RAW-SECRET-QR')

      get "#{base_path}/#{record.inbox_id}/qr", headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
      expect(json['data_url']).to eq('data:image/png;base64,AAAA')
      expect(json['available']).to be(true)
      expect(response.body).not_to include('RAW-SECRET-QR')
      expect(json).not_to have_key('raw_qr')
      expect(json).not_to have_key('qr')
    end

    it 'drops a data URL that is not a bounded base64 PNG (reports unavailable)' do
      record = mapping_for(account, status: 'waiting_for_qr')
      allow(client).to receive(:qr)
        .and_return('available' => true, 'data_url' => 'javascript:alert(1)')

      get "#{base_path}/#{record.inbox_id}/qr", headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
      expect(json['available']).to be(false)
      expect(json['data_url']).to be_nil
      expect(response.body).not_to include('javascript:')
    end
  end

  describe 'control actions' do
    around { |example| with_modified_env(env) { example.run } }
    before { allow(client_klass).to receive(:new).and_return(client) }

    it 'reconnect returns a safe DTO reflecting the new status' do
      record = mapping_for(account, status: 'disconnected')
      allow(client).to receive(:reconnect).and_return('id' => 'sess-1', 'status' => 'connecting')

      post "#{base_path}/#{record.inbox_id}/reconnect", headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
      expect(json['status']).to eq('connecting')
      expect(record.reload.status).to eq('connecting')
    end

    it 'logout keeps the inbox and reflects logged_out' do
      record = mapping_for(account, status: 'connected')
      allow(client).to receive(:logout).and_return('status' => 'logged_out')

      post "#{base_path}/#{record.inbox_id}/logout", headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
      expect(json['status']).to eq('logged_out')
      expect(Inbox.exists?(record.inbox_id)).to be(true)
    end

    it 'retry re-enqueues provisioning' do
      allow(job_klass).to receive(:perform_later)
      record = mapping_for(account, session_id: nil, status: 'error')

      post "#{base_path}/#{record.inbox_id}/retry", headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
      expect(job_klass).to have_received(:perform_later).with(record_id: record.id)
    end
  end
end
