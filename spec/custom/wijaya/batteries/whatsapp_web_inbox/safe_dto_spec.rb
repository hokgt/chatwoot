# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WhatsappWebInbox::SafeDto do
  let(:account) { create(:account) }
  let(:record_klass) { Wijaya::Batteries::WhatsappWebInbox::Record }

  def mapping(status: 'waiting_for_qr')
    channel = account.api_channels.create!(hmac_mandatory: true,
                                           additional_attributes: { 'wijaya_provider' => 'whatsapp_web' })
    inbox = account.inboxes.create!(name: 'WA', channel: channel)
    record_klass.create!(account: account, inbox: inbox, request_token: SecureRandom.uuid,
                         connector_session_id: 'sess-1', provisioning_state: 'provisioned', status: status)
  end

  describe '.qr' do
    it 'forwards a valid bounded base64 PNG data URL and marks it available' do
      dto = described_class.qr(mapping, { 'available' => true, 'data_url' => 'data:image/png;base64,AAAB' })
      expect(dto[:available]).to be(true)
      expect(dto[:data_url]).to eq('data:image/png;base64,AAAB')
    end

    it 'drops a non-PNG data URL' do
      dto = described_class.qr(mapping, { 'available' => true, 'data_url' => 'data:image/svg+xml;base64,AAAB' })
      expect(dto[:available]).to be(false)
      expect(dto[:data_url]).to be_nil
    end

    it 'drops a non-data-URL string (e.g. a javascript: payload)' do
      dto = described_class.qr(mapping, { 'available' => true, 'data_url' => 'javascript:alert(1)' })
      expect(dto[:available]).to be(false)
      expect(dto[:data_url]).to be_nil
    end

    it 'drops a data URL whose base64 payload contains unexpected characters' do
      dto = described_class.qr(mapping, { 'available' => true, 'data_url' => 'data:image/png;base64,<script>' })
      expect(dto[:available]).to be(false)
      expect(dto[:data_url]).to be_nil
    end

    it 'drops an oversized data URL' do
      oversized = "data:image/png;base64,#{'A' * (described_class::MAX_QR_DATA_URL_BYTES + 1)}"
      dto = described_class.qr(mapping, { 'available' => true, 'data_url' => oversized })
      expect(dto[:available]).to be(false)
      expect(dto[:data_url]).to be_nil
    end

    it 'reports unavailable when the connector is unavailable even with a plausible data URL' do
      dto = described_class.qr(mapping, { 'available' => true, 'data_url' => 'data:image/png;base64,AAAB' },
                               connector_available: false)
      expect(dto[:connector_available]).to be(false)
      expect(dto[:available]).to be(false)
      expect(dto[:data_url]).to be_nil
    end
  end

  describe '.safe_data_url' do
    it 'rejects a blank base64 payload' do
      expect(described_class.safe_data_url('data:image/png;base64,')).to be_nil
    end

    it 'accepts a padded base64 payload' do
      expect(described_class.safe_data_url('data:image/png;base64,QQ==')).to eq('data:image/png;base64,QQ==')
    end

    it 'rejects non-strings' do
      expect(described_class.safe_data_url(nil)).to be_nil
      expect(described_class.safe_data_url(123)).to be_nil
    end
  end

  describe '.mask_jid' do
    it 'masks to the last four digits' do
      expect(described_class.mask_jid('6281234567890@s.whatsapp.net')).to eq('••••7890')
    end

    it 'returns nil for a blank/identifier-less value' do
      expect(described_class.mask_jid(nil)).to be_nil
      expect(described_class.mask_jid('@s.whatsapp.net')).to be_nil
    end
  end
end
