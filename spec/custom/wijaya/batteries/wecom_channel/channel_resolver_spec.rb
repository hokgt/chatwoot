# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WecomChannel::ChannelResolver do
  describe '.siblings' do
    it 'returns every channel for a corp, ordered by id, and none for a blank corp' do
      corp = 'ww_shared_corp'
      a = create(:channel_wecom, corp_id: corp)
      b = create(:channel_wecom, corp_id: corp)
      create(:channel_wecom, corp_id: 'ww_other_corp')

      expect(described_class.siblings(corp).to_a).to eq([a, b])
      expect(described_class.siblings('')).to be_empty
    end
  end

  describe '.route_event' do
    it 'routes to the inbox with the matching open_kfid within the same corp' do
      corp = 'ww_shared_corp'
      target = create(:channel_wecom, corp_id: corp, open_kfid: 'wk_target')
      create(:channel_wecom, corp_id: corp, open_kfid: 'wk_other')

      expect(described_class.route_event(corp, 'wk_target')).to eq(target)
    end

    it 'never crosses corp boundaries' do
      create(:channel_wecom, corp_id: 'ww_corp_a', open_kfid: 'wk_shared')
      expect(described_class.route_event('ww_corp_b', 'wk_shared')).to be_nil
    end

    it 'returns nil for a blank open_kfid or corp' do
      expect(described_class.route_event('ww_corp', '')).to be_nil
      expect(described_class.route_event('', 'wk')).to be_nil
    end
  end
end
