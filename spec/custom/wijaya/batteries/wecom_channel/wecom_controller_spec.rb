# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'WeCom callback webhook', type: :request do
  let(:corp_id) { 'ww_test_corp' }
  let(:token) { 'inert-token' }
  let(:encoding_aes_key) { Base64.strict_encode64(SecureRandom.random_bytes(32))[0, 43] }
  let!(:channel) do
    create(:channel_wecom, corp_id: corp_id, token: token, encoding_aes_key: encoding_aes_key, open_kfid: 'wk_target')
  end
  let(:crypto) do
    Wijaya::Batteries::WecomChannel::Crypto.new(token: token, encoding_aes_key: encoding_aes_key, receive_id: corp_id)
  end
  let(:timestamp) { '1700000000' }
  let(:nonce) { 'nonce123' }

  describe 'GET /webhooks/wecom/:corp_id (URL verification)' do
    it 'echoes the decrypted echostr for a valid signature, even before a Secret exists' do
      channel.update!(secret: nil, open_kfid: nil)
      echostr = crypto.encrypt('verification-plaintext')
      sig = crypto.signature(timestamp, nonce, echostr)

      get "/webhooks/wecom/#{corp_id}", params: { msg_signature: sig, timestamp: timestamp, nonce: nonce, echostr: echostr }

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('verification-plaintext')
    end

    it 'rejects a tampered signature with 401' do
      echostr = crypto.encrypt('verification-plaintext')
      get "/webhooks/wecom/#{corp_id}", params: { msg_signature: 'deadbeef', timestamp: timestamp, nonce: nonce, echostr: echostr }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 401 for an unknown corp' do
      echostr = crypto.encrypt('x')
      sig = crypto.signature(timestamp, nonce, echostr)
      get '/webhooks/wecom/ww_unknown', params: { msg_signature: sig, timestamp: timestamp, nonce: nonce, echostr: echostr }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'POST /webhooks/wecom/:corp_id (event callback)' do
    def post_event(open_kfid:, event: 'kf_msg_or_event', sync_token: 'sync-token-abc')
      plaintext = "<xml><Event><![CDATA[#{event}]]></Event>" \
                  "<OpenKfId><![CDATA[#{open_kfid}]]></OpenKfId><Token><![CDATA[#{sync_token}]]></Token></xml>"
      encrypt = crypto.encrypt(plaintext)
      sig = crypto.signature(timestamp, nonce, encrypt)
      body = "<xml><Encrypt><![CDATA[#{encrypt}]]></Encrypt></xml>"
      post "/webhooks/wecom/#{corp_id}?msg_signature=#{sig}&timestamp=#{timestamp}&nonce=#{nonce}",
           params: body, headers: { 'CONTENT_TYPE' => 'application/xml' }
    end

    it 'enqueues a sync job for the inbox matching the decrypted OpenKfId and returns 200' do
      expect do
        post_event(open_kfid: 'wk_target')
      end.to have_enqueued_job(Wijaya::Batteries::WecomChannel::SyncMessagesJob)
        .with(channel_id: channel.id, token: 'sync-token-abc', open_kfid: 'wk_target')
      expect(response).to have_http_status(:ok)
    end

    it 'does not enqueue when the OpenKfId is unknown within the corp' do
      expect do
        post_event(open_kfid: 'wk_unknown')
      end.not_to have_enqueued_job(Wijaya::Batteries::WecomChannel::SyncMessagesJob)
      expect(response).to have_http_status(:ok)
    end

    it 'rejects a payload encrypted for a different corp with 401' do
      other = Wijaya::Batteries::WecomChannel::Crypto.new(token: token, encoding_aes_key: encoding_aes_key, receive_id: 'ww_evil')
      encrypt = other.encrypt('<xml><Event>kf_msg_or_event</Event></xml>')
      sig = crypto.signature(timestamp, nonce, encrypt)
      body = "<xml><Encrypt><![CDATA[#{encrypt}]]></Encrypt></xml>"
      post "/webhooks/wecom/#{corp_id}?msg_signature=#{sig}&timestamp=#{timestamp}&nonce=#{nonce}",
           params: body, headers: { 'CONTENT_TYPE' => 'application/xml' }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
