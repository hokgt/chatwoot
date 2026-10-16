# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WhatsappWebInbox::Hooks do
  let(:message) { Message.new }

  def channel(provider: 'whatsapp_web')
    attrs = provider.nil? ? {} : { 'wijaya_provider' => provider }
    OpenStruct.new(additional_attributes: attrs)
  end

  def params(hash)
    ActionController::Parameters.new(hash)
  end

  describe '.apply_public_inbound_message_attributes' do
    it 'sets source_id and in_reply_to_external_id for a whatsapp_web inbox' do
      described_class.apply_public_inbound_message_attributes(
        message: message,
        channel: channel,
        params: params('source_id' => 'wamid.IN1', 'in_reply_to_external_id' => 'wamid.Q1')
      )
      expect(message.source_id).to eq('wamid.IN1')
      expect(message.content_attributes['in_reply_to_external_id']).to eq('wamid.Q1')
    end

    it 'does nothing for a non-whatsapp_web inbox (no arbitrary assignment)' do
      described_class.apply_public_inbound_message_attributes(
        message: message,
        channel: channel(provider: nil),
        params: params('source_id' => 'wamid.IN1', 'in_reply_to_external_id' => 'wamid.Q1')
      )
      expect(message.source_id).to be_nil
      expect(message.content_attributes['in_reply_to_external_id']).to be_nil
    end

    it 'rejects malformed provider ids' do
      described_class.apply_public_inbound_message_attributes(
        message: message,
        channel: channel,
        params: params('source_id' => "bad id with spaces\nand newline", 'in_reply_to_external_id' => '')
      )
      expect(message.source_id).to be_nil
      expect(message.content_attributes['in_reply_to_external_id']).to be_nil
    end

    it 'sets only source_id when no reply id is supplied' do
      described_class.apply_public_inbound_message_attributes(
        message: message, channel: channel, params: params('source_id' => 'wamid.IN2')
      )
      expect(message.source_id).to eq('wamid.IN2')
      expect(message.content_attributes['in_reply_to_external_id']).to be_nil
    end
  end
end
