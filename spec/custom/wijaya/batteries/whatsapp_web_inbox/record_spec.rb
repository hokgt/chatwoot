# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WhatsappWebInbox::Record do
  let(:account) { create(:account) }
  let(:cleanup_job) { Wijaya::Batteries::WhatsappWebInbox::CleanupJob }

  def build_mapping(session_id: nil, token: 'tok')
    channel = account.api_channels.create!(hmac_mandatory: true,
                                           additional_attributes: { 'wijaya_provider' => 'whatsapp_web' })
    inbox = account.inboxes.create!(name: 'WA', channel: channel)
    described_class.create!(account: account, inbox: inbox, request_token: token,
                            connector_session_id: session_id, status: 'unconfigured',
                            provisioning_state: 'pending')
  end

  describe 'validations' do
    it 'requires a unique inbox_id' do
      record = build_mapping(token: 'a')
      dup = described_class.new(account: account, inbox: record.inbox, request_token: 'b')
      expect(dup).not_to be_valid
    end

    it 'requires a unique request_token' do
      build_mapping(token: 'same')
      channel = account.api_channels.create!
      inbox = account.inboxes.create!(name: 'WA2', channel: channel)
      dup = described_class.new(account: account, inbox: inbox, request_token: 'same')
      expect(dup).not_to be_valid
    end

    it 'rejects an out-of-set status or provisioning_state' do
      record = build_mapping(token: 'c')
      record.status = 'bogus'
      expect(record).not_to be_valid
      record.status = 'connected'
      record.provisioning_state = 'bogus'
      expect(record).not_to be_valid
    end
  end

  describe '.sanitize_status' do
    it 'passes through a known status and coerces anything else to error' do
      expect(described_class.sanitize_status('connected')).to eq('connected')
      expect(described_class.sanitize_status('weird')).to eq('error')
      expect(described_class.sanitize_status(nil)).to eq('error')
    end
  end

  describe 'connector cleanup on deletion' do
    it 'enqueues cleanup with the session id when one is present' do
      allow(cleanup_job).to receive(:perform_later)
      record = build_mapping(session_id: 'sess-1', token: 'd')
      record.send(:enqueue_connector_cleanup)
      expect(cleanup_job).to have_received(:perform_later).with(connector_session_id: 'sess-1')
    end

    it 'does not enqueue cleanup when there is no session id' do
      allow(cleanup_job).to receive(:perform_later)
      record = build_mapping(session_id: nil, token: 'e')
      record.send(:enqueue_connector_cleanup)
      expect(cleanup_job).not_to have_received(:perform_later)
    end
  end

  describe 'inbox association' do
    it 'is reachable from the inbox and destroyed with it' do
      record = build_mapping(token: 'f')
      inbox = record.inbox
      expect(inbox.wijaya_whatsapp_web_inbox).to eq(record)
      inbox.destroy
      expect(described_class.exists?(record.id)).to be(false)
    end
  end
end
