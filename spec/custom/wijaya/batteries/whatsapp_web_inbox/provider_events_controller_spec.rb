# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Wijaya WhatsApp Web provider events', type: :request do
  let(:account) { create(:account) }
  let(:channel) do
    account.api_channels.create!(hmac_mandatory: true,
                                 additional_attributes: { 'wijaya_provider' => 'whatsapp_web' })
  end
  let(:inbox) { account.inboxes.create!(name: 'WA', channel: channel) }
  let!(:mapping) do
    Wijaya::Batteries::WhatsappWebInbox::Record.create!(
      account: account, inbox: inbox, request_token: SecureRandom.uuid,
      connector_session_id: 'sess-1', provisioning_state: 'provisioned', status: 'connected'
    )
  end
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact_inbox: contact_inbox) }
  let(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing)
  end

  def path(identifier = channel.identifier)
    "/public/api/v1/wijaya/whatsapp_web/provider_events/#{identifier}"
  end

  def body_for(over = {})
    {
      session_id: 'sess-1',
      inbox_identifier: channel.identifier,
      chatwoot_message_id: message.id,
      provider_message_id: 'wamid.OUT1',
      status: 'delivered'
    }.merge(over)
  end

  def signed_headers(raw, secret: channel.secret, timestamp: Time.now.to_i, uuid: SecureRandom.uuid)
    sig = OpenSSL::HMAC.hexdigest('sha256', secret, "#{timestamp}.#{raw}")
    {
      'X-Wijaya-Delivery' => uuid,
      'X-Wijaya-Timestamp' => timestamp.to_s,
      'X-Wijaya-Signature' => sig,
      'CONTENT_TYPE' => 'application/json'
    }
  end

  def post_event(over = {}, header_opts = {})
    raw = body_for(over).to_json
    post path, params: raw, headers: signed_headers(raw, **header_opts)
  end

  describe 'valid status transitions' do
    it 'applies delivered' do
      post_event(status: 'delivered')
      expect(response).to have_http_status(:ok)
      expect(message.reload.status).to eq('delivered')
    end

    it 'applies read' do
      post_event(status: 'read')
      expect(response).to have_http_status(:ok)
      expect(message.reload.status).to eq('read')
    end

    it 'applies failed with a sanitized generic external error' do
      post_event(status: 'failed')
      expect(response).to have_http_status(:ok)
      expect(message.reload.status).to eq('failed')
      expect(message.content_attributes['external_error']).to eq('provider_delivery_failed')
    end

    it "'sent' on an already-sent message is an idempotent success" do
      expect(message.status).to eq('sent')
      post_event(status: 'sent')
      expect(response).to have_http_status(:ok)
      expect(message.reload.status).to eq('sent')
    end

    it 'back-fills source_id when blank' do
      post_event(status: 'delivered', provider_message_id: 'wamid.BACKFILL')
      expect(message.reload.source_id).to eq('wamid.BACKFILL')
    end
  end

  describe 'monotonic guard' do
    it 'never downgrades read -> delivered (idempotent success, no change)' do
      Messages::StatusUpdateService.new(message, 'read').perform
      post_event(status: 'delivered')
      expect(response).to have_http_status(:ok)
      expect(message.reload.status).to eq('read')
    end
  end

  describe 'idempotency and replay' do
    it 'treats an exact delivery-UUID replay as an idempotent success' do
      raw = body_for(status: 'delivered').to_json
      headers = signed_headers(raw)
      post path, params: raw, headers: headers
      expect(response).to have_http_status(:ok)
      post path, params: raw, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['status']).to eq('duplicate')
    end
  end

  describe 'authentication failures (fail closed)' do
    it 'rejects a stale timestamp' do
      post_event({ status: 'delivered' }, { timestamp: Time.now.to_i - 10_000 })
      expect(response).to have_http_status(:unauthorized)
      expect(message.reload.status).to eq('sent')
    end

    it 'rejects a bad signature' do
      post_event({ status: 'delivered' }, { secret: 'wrong-secret' })
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects missing signature headers' do
      raw = body_for.to_json
      post path, params: raw, headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'scoping and schema' do
    it 'returns 404 for an unknown inbox identifier' do
      raw = body_for.to_json
      post path('nonexistent-identifier'), params: raw, headers: signed_headers(raw)
      expect(response).to have_http_status(:not_found)
    end

    it 'rejects a mismatched session_id' do
      post_event(session_id: 'other-session')
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects a body inbox_identifier that differs from the path' do
      post_event(inbox_identifier: 'different')
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects a message that belongs to a different account/inbox' do
      other = create(:account)
      other_channel = other.api_channels.create!(additional_attributes: { 'wijaya_provider' => 'whatsapp_web' })
      other_inbox = other.inboxes.create!(name: 'O', channel: other_channel)
      foreign = create(:conversation, account: other, inbox: other_inbox)
      foreign_message = create(:message, account: other, inbox: other_inbox, conversation: foreign, message_type: :outgoing)
      post_event(chatwoot_message_id: foreign_message.id)
      expect(response).to have_http_status(:not_found)
    end

    it 'rejects an incoming (non-outgoing) message' do
      incoming = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
      post_event(chatwoot_message_id: incoming.id)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects a malformed body' do
      raw = 'not json'
      post path, params: raw, headers: signed_headers(raw)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects an unknown status value' do
      post_event(status: 'exploded')
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'infrastructure failures (fail closed)' do
    it 'returns 503 when the replay store is unavailable' do
      allow(Redis::Alfred).to receive(:set).and_raise(StandardError.new('redis down'))
      post_event(status: 'delivered')
      expect(response).to have_http_status(:service_unavailable)
      expect(message.reload.status).to eq('sent')
    end
  end
end
