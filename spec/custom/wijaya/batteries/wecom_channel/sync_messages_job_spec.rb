# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WecomChannel::SyncMessagesJob do
  let(:channel) { create(:channel_wecom, sync_cursor: 'cursor-0') }
  let(:api) { instance_double(Wijaya::Batteries::WecomChannel::ApiClient) }

  before do
    allow(Wijaya::Batteries::WecomChannel::ApiClient).to receive(:new).and_return(api)
    # Each message goes through its own InboundMessageService; a payload whose msgid is
    # 'BAD' raises to simulate a transient/per-message failure, everything else succeeds.
    allow(Wijaya::Batteries::WecomChannel::InboundMessageService).to receive(:new) do |payload:, **|
      instance_double(Wijaya::Batteries::WecomChannel::InboundMessageService).tap do |service|
        if payload['msgid'] == 'BAD'
          allow(service).to receive(:perform).and_raise(StandardError, 'boom')
        else
          allow(service).to receive(:perform)
        end
      end
    end
  end

  def run
    described_class.perform_now(channel_id: channel.id, token: 'tok', open_kfid: 'wk1')
  end

  it 'does not advance the cursor and re-raises when a message fails' do
    allow(api).to receive(:sync_msg).and_return(
      'msg_list' => [{ 'msgid' => 'OK' }, { 'msgid' => 'BAD' }], 'next_cursor' => 'cursor-1', 'has_more' => 0
    )

    expect { run }.to raise_error(StandardError)
    expect(channel.reload.sync_cursor).to eq('cursor-0')
  end

  it 'advances the cursor after a page is processed successfully' do
    allow(api).to receive(:sync_msg).and_return(
      'msg_list' => [{ 'msgid' => 'OK1' }, { 'msgid' => 'OK2' }], 'next_cursor' => 'cursor-1', 'has_more' => 0
    )

    run
    expect(channel.reload.sync_cursor).to eq('cursor-1')
  end

  it 'sizes the mutex TTL to cover the worst-case paging budget (well above one minute)' do
    expect(described_class::LOCK_TTL).to be > 1.minute
  end
end
