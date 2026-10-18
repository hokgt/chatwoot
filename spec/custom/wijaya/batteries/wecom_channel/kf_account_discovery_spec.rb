# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WecomChannel::KfAccountDiscovery do
  let(:channel) { create(:channel_wecom, secret: 'a-secret', open_kfid: nil) }
  let(:api) { instance_double(Wijaya::Batteries::WecomChannel::ApiClient) }

  before { allow(Wijaya::Batteries::WecomChannel::ApiClient).to receive(:new).and_return(api) }

  it 'auto-fills Open KF ID when the corp has exactly one KF account' do
    allow(api).to receive(:kf_account_list).and_return('account_list' => [{ 'open_kfid' => 'wk_only', 'name' => 'Support' }])

    described_class.new(channel: channel).perform

    expect(channel.reload.open_kfid).to eq('wk_only')
  end

  it 'does NOT choose when the corp exposes multiple KF accounts (no silent ambiguity)' do
    allow(api).to receive(:kf_account_list)
      .and_return('account_list' => [{ 'open_kfid' => 'wk_a' }, { 'open_kfid' => 'wk_b' }])

    described_class.new(channel: channel).perform

    expect(channel.reload.open_kfid).to be_blank
  end

  it 'no-ops when Open KF ID is already set' do
    channel.update_column(:open_kfid, 'wk_existing')
    expect(api).not_to receive(:kf_account_list)

    described_class.new(channel: channel).perform

    expect(channel.reload.open_kfid).to eq('wk_existing')
  end
end
