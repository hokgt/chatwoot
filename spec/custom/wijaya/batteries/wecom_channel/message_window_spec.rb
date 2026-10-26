# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::MessageWindowService do
  let(:channel) { create(:channel_wecom) }
  let(:conversation) { create(:conversation, inbox: channel.inbox, account: channel.account) }

  it 'allows replies within WeCom 48-hour window' do
    create(:message, conversation: conversation, account: conversation.account, message_type: :incoming, created_at: 10.hours.ago)
    expect(described_class.new(conversation).can_reply?).to be(true)
  end

  it 'blocks replies after the WeCom 48-hour window (drives the reply-box warning)' do
    create(:message, conversation: conversation, account: conversation.account, message_type: :incoming, created_at: 49.hours.ago)
    expect(described_class.new(conversation).can_reply?).to be(false)
  end
end
