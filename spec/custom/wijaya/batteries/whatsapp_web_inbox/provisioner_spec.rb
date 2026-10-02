# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WhatsappWebInbox::Provisioner do
  let(:account) { create(:account) }
  let(:record_klass) { Wijaya::Batteries::WhatsappWebInbox::Record }
  let(:client_klass) { Wijaya::Batteries::WhatsappWebInbox::ConnectorClient }
  let(:job_klass) { Wijaya::Batteries::WhatsappWebInbox::ProvisionJob }
  let(:env) do
    {
      'WHATSAPP_WEB_CONNECTOR_URL' => 'http://wa-connector:3000',
      'WHATSAPP_WEB_CONNECTOR_HMAC_SECRET' => 'svc',
      'FRONTEND_URL' => 'https://chat.example.com'
    }
  end

  before { allow(job_klass).to receive(:perform_later) }

  describe '#create!' do
    it 'creates a hmac_mandatory Channel::Api with the provider marker, the inbox, and a pending mapping' do
      record = described_class.new(account: account).create!(name: 'Sales WA', request_token: 'tok-1')

      channel = record.inbox.channel
      expect(channel).to be_a(Channel::Api)
      expect(channel.hmac_mandatory).to be(true)
      expect(channel.additional_attributes['wijaya_provider']).to eq('whatsapp_web')
      expect(channel.identifier).to be_present
      expect(record.inbox.name).to eq('Sales WA')
      expect(record.provisioning_state).to eq('pending')
      expect(record.connector_session_id).to be_nil
      expect(channel.webhook_url).to be_blank
      expect(job_klass).to have_received(:perform_later).with(record_id: record.id)
    end

    it 'is idempotent for a duplicate request token (no second inbox)' do
      first = described_class.new(account: account).create!(name: 'A', request_token: 'dup')
      second = described_class.new(account: account).create!(name: 'B', request_token: 'dup')

      expect(second.id).to eq(first.id)
      expect(account.inboxes.count).to eq(1)
    end

    it 'scopes the request token per account: another account reusing the same token gets its own mapping' do
      first = described_class.new(account: account).create!(name: 'A', request_token: 'shared')
      other = create(:account)
      second = described_class.new(account: other).create!(name: 'B', request_token: 'shared')

      expect(second).to be_present
      expect(second.id).not_to eq(first.id)
      expect(second.account_id).to eq(other.id)
      expect(account.inboxes.count).to eq(1)
      expect(other.inboxes.count).to eq(1)
    end
  end

  describe '#provision_session!' do
    let(:record) { described_class.new(account: account).create!(name: 'WA', request_token: 'tok-9') }
    let(:channel) { record.inbox.channel }
    let(:client) { instance_double(client_klass) }

    around { |example| with_modified_env(env) { example.run } }
    before { allow(client_klass).to receive(:new).and_return(client) }

    it 'creates a session, sets the webhook only after the session exists, and marks provisioned' do
      allow(client).to receive(:list_sessions).and_return('sessions' => [])
      allow(client).to receive(:create_session).and_return('id' => 'sess-1', 'status' => 'waiting_for_qr')

      expect(channel.webhook_url).to be_blank
      described_class.new(account: account).provision_session!(record)

      record.reload
      expect(record.connector_session_id).to eq('sess-1')
      expect(record.provisioning_state).to eq('provisioned')
      expect(record.status).to eq('waiting_for_qr')
      expect(channel.reload.webhook_url).to eq('http://wa-connector:3000/webhooks/chatwoot/sess-1')
      expect(client).to have_received(:create_session).with(
        hash_including(hmacMandatory: true, inboxIdentifier: channel.identifier,
                       hmacToken: channel.hmac_token, webhookSecret: channel.secret,
                       baseUrl: 'https://chat.example.com', accountId: account.id)
      )
    end

    it 'adopts an existing session with the same inboxIdentifier instead of creating a duplicate' do
      existing = { 'id' => 'existing-1', 'status' => 'connected',
                   'chatwoot' => { 'inboxIdentifier' => channel.identifier, 'accountId' => account.id } }
      allow(client).to receive(:list_sessions).and_return('sessions' => [existing])
      expect(client).not_to receive(:create_session)

      described_class.new(account: account).provision_session!(record)
      expect(record.reload.connector_session_id).to eq('existing-1')
    end

    it 'adopts the already-linked session by id (idempotent re-run)' do
      record.update!(connector_session_id: 'sess-x')
      allow(client).to receive(:get_session).with('sess-x').and_return('id' => 'sess-x', 'status' => 'connected')
      expect(client).not_to receive(:list_sessions)

      described_class.new(account: account).provision_session!(record)
      expect(record.reload.status).to eq('connected')
    end

    it 'leaves a recoverable error mapping and re-raises on connector outage (inbox kept)' do
      allow(client).to receive(:list_sessions).and_raise(client_klass::ConnectorUnavailable)

      expect { described_class.new(account: account).provision_session!(record) }
        .to raise_error(client_klass::ConnectorUnavailable)
      record.reload
      expect(record.provisioning_state).to eq('error')
      expect(record.last_error_code).to eq('connector_unavailable')
      expect(Inbox.exists?(record.inbox_id)).to be(true)
    end

    it 'coerces an unknown connector status to error before storing it' do
      allow(client).to receive(:list_sessions).and_return('sessions' => [])
      allow(client).to receive(:create_session).and_return('id' => 'sess-2', 'status' => 'totally-bogus')

      described_class.new(account: account).provision_session!(record)
      expect(record.reload.status).to eq('error')
    end
  end
end
