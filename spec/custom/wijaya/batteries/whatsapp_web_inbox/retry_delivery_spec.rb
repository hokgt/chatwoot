# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WhatsappWebInbox::RetryDelivery do
  let(:account) { create(:account) }
  let(:wa_channel) do
    account.api_channels.create!(hmac_mandatory: true,
                                 webhook_url: 'https://connector.internal/webhooks/wa',
                                 additional_attributes: { 'wijaya_provider' => 'whatsapp_web' })
  end
  let(:wa_inbox) { account.inboxes.create!(name: 'WA', channel: wa_channel) }
  let(:plain_channel) { account.api_channels.create!(webhook_url: 'https://example.com/hook') }
  let(:plain_inbox) { account.inboxes.create!(name: 'API', channel: plain_channel) }

  def outgoing_message(inbox, status: 'failed', external_error: '503 Service Unavailable', source_id: nil)
    contact = create(:contact, account: account)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
    conversation = create(:conversation, account: account, inbox: inbox, contact_inbox: contact_inbox)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :outgoing, status: status, external_error: external_error,
                     source_id: source_id)
  end

  before { allow(Webhooks::Trigger).to receive(:execute) }

  describe '.perform gating' do
    it 'returns false for a non-whatsapp_web api inbox (native retry runs)' do
      message = outgoing_message(plain_inbox)
      expect(described_class.perform(message: message)).to be(false)
      expect(Webhooks::Trigger).not_to have_received(:execute)
    end

    it 'returns false for an incoming whatsapp_web message' do
      message = outgoing_message(wa_inbox)
      message.update!(message_type: :incoming)
      expect(described_class.perform(message: message)).to be(false)
      expect(Webhooks::Trigger).not_to have_received(:execute)
    end
  end

  describe '.perform re-delivery of a failed whatsapp_web message' do
    it 're-emits a message.created api_inbox webhook through the native signed trigger' do
      message = outgoing_message(wa_inbox)

      expect(described_class.perform(message: message)).to be(true)

      expect(Webhooks::Trigger).to have_received(:execute).with(
        wa_channel.webhook_url,
        hash_including(event: 'message_created', id: message.id),
        :api_inbox_webhook,
        hash_including(secret: wa_channel.secret, delivery_id: a_kind_of(String))
      )
    end

    it 'clears the failure and puts the message into a sent retry state' do
      message = outgoing_message(wa_inbox)

      described_class.perform(message: message)

      expect(message.reload.status).to eq('sent')
      expect(message.external_error).to be_blank
    end
  end

  describe 'connector failure stays failed (never shown as sent)' do
    it 'reflects the failed status the trigger writes on a connector 503' do
      message = outgoing_message(wa_inbox)
      allow(Webhooks::Trigger).to receive(:execute) do
        Message.find(message.id).update!(status: :failed, external_error: '503 Service Unavailable')
      end

      described_class.perform(message: message)

      expect(message.reload.status).to eq('failed')
    end
  end

  describe 'idempotency / no duplicate provider send' do
    it 'never re-sends a message that already carries a provider id' do
      message = outgoing_message(wa_inbox, source_id: 'wamid.OUT1')

      expect(described_class.perform(message: message)).to be(true)
      expect(Webhooks::Trigger).not_to have_received(:execute)
    end

    it 'coalesces a duplicate retry inside the lock window into a single send' do
      message = outgoing_message(wa_inbox)

      described_class.perform(message: message)
      message.update!(status: :failed, external_error: '503 Service Unavailable')
      expect(described_class.perform(message: message)).to be(true)

      expect(Webhooks::Trigger).to have_received(:execute).once
    end

    it 'does not re-send when the retry slot cannot be claimed (fail closed)' do
      message = outgoing_message(wa_inbox)
      allow(Redis::Alfred).to receive(:set).and_return(false)

      expect(described_class.perform(message: message)).to be(true)
      expect(Webhooks::Trigger).not_to have_received(:execute)
    end
  end
end
