# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WecomChannel::InboundMessageService do
  let(:channel) { create(:channel_wecom) }
  let(:inbox) { channel.inbox }

  before do
    api = instance_double(Wijaya::Batteries::WecomChannel::ApiClient)
    allow(Wijaya::Batteries::WecomChannel::ApiClient).to receive(:new).and_return(api)
    allow(api).to receive(:batch_customer).and_return('customer_list' => [{ 'nickname' => 'Mei', 'avatar' => nil }])
  end

  def payload(overrides = {})
    {
      'msgid' => 'MSG-1', 'origin' => 3, 'external_userid' => 'wmExternal', 'send_time' => 1_700_000_000,
      'msgtype' => 'text', 'text' => { 'content' => 'hello' }
    }.merge(overrides).with_indifferent_access
  end

  it 'creates an incoming message for a customer-origin text message' do
    expect { described_class.new(channel: channel, payload: payload).perform }
      .to change { inbox.messages.count }.by(1)
    message = inbox.messages.last
    expect(message.content).to eq('hello')
    expect(message.message_type).to eq('incoming')
    expect(message.source_id).to eq('MSG-1')
  end

  it 'is idempotent on msgid (re-pulling a cursor batch never duplicates)' do
    described_class.new(channel: channel, payload: payload).perform
    expect { described_class.new(channel: channel, payload: payload).perform }
      .not_to(change { inbox.messages.count })
  end

  it 'skips non-customer-origin entries (origin != 3)' do
    expect { described_class.new(channel: channel, payload: payload('origin' => 4, 'msgid' => 'MSG-2')).perform }
      .not_to(change { inbox.messages.count })
  end

  it 'renders the exact placeholder for an unknown message type' do
    described_class.new(channel: channel, payload: payload('msgtype' => 'miniprogram', 'msgid' => 'MSG-3', 'text' => nil)).perform
    expect(inbox.messages.last.content).to eq('Unsupported WeCom message type: miniprogram')
  end

  it 'deterministically skips a blank-text payload without raising (so it never poisons the sync)' do
    expect do
      described_class.new(channel: channel, payload: payload('msgid' => 'MSG-4', 'text' => { 'content' => '   ' })).perform
    end.not_to(change { inbox.messages.count })
  end
end
