# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WecomChannel::SendOnWecomService do
  let(:channel) { create(:channel_wecom, open_kfid: 'wk_kf') }
  let(:inbox) { channel.inbox }
  let(:contact_inbox) { create(:contact_inbox, inbox: inbox, source_id: 'wmExternal') }
  let(:conversation) { create(:conversation, inbox: inbox, contact_inbox: contact_inbox, account: inbox.account) }
  let(:message) { create(:message, conversation: conversation, account: inbox.account, message_type: :outgoing, content: 'hi there') }
  let(:api) { instance_double(Wijaya::Batteries::WecomChannel::ApiClient) }

  before { allow(Wijaya::Batteries::WecomChannel::ApiClient).to receive(:new).and_return(api) }

  it 'sends text to the external user and marks the message delivered with the WeCom msgid' do
    expect(api).to receive(:send_text)
      .with(touser: 'wmExternal', open_kfid: 'wk_kf', content: 'hi there')
      .and_return('msgid' => 'WECOM-MSG-1')

    described_class.new(message: message).perform

    expect(message.reload.source_id).to eq('WECOM-MSG-1')
    expect(message.status).to eq('delivered')
  end

  it 'marks the message failed with the provider errcode and errmsg text on an API error' do
    error = Wijaya::Batteries::WecomChannel::ApiClient::Error.new('wecom api error 95000: api freq out of limit', errcode: 95_000)
    allow(api).to receive(:send_text).and_raise(error)

    described_class.new(message: message).perform

    expect(message.reload.status).to eq('failed')
    expect(message.external_error).to include('95000')
    expect(message.external_error).to include('api freq out of limit')
  end
end
