# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/meta_ads_team_routing/routing_service')

RSpec.describe Wijaya::Batteries::MetaAdsTeamRouting::RoutingService do
  subject(:apply) do
    described_class.apply!(
      account: account,
      inbox: inbox,
      channel: channel,
      referral: referral,
      conversation_params: conversation_params
    )
  end

  let(:account) { instance_double(Account, id: 7) }
  let(:inbox) { instance_double(Inbox) }
  let(:conversation_params) { { account_id: 7, inbox_id: 3 } }
  let(:rules_relation) { instance_double(ActiveRecord::Relation) }
  let(:rule) { instance_double(Wijaya::MetaAdsTeamRoutingRule, team_id: 55) }

  before do
    allow(Wijaya::MetaAdsTeamRoutingRule).to receive(:active).and_return(rules_relation)
    allow(rules_relation).to receive(:find_by).and_return(nil)
  end

  context 'when a WhatsApp referral maps to an active rule' do
    let(:channel) { :whatsapp }
    let(:referral) { { source_id: 'AD_123', source_type: 'ad' } }

    before do
      allow(rules_relation).to receive(:find_by).with(account_id: 7, source_id: 'AD_123').and_return(rule)
    end

    it 'injects only team_id' do
      expect(apply[:team_id]).to eq(55)
    end
  end

  context 'when a Messenger referral (ad_id) maps to an active rule' do
    let(:channel) { :messenger }
    let(:referral) { { ad_id: 'AD_MSG', source: 'ads' } }

    before do
      allow(rules_relation).to receive(:find_by).with(account_id: 7, source_id: 'AD_MSG').and_return(rule)
    end

    it 'injects team_id' do
      expect(apply[:team_id]).to eq(55)
    end
  end

  context 'when an Instagram referral (ad_id) maps to an active rule' do
    let(:channel) { :instagram }
    let(:referral) { { ad_id: 'AD_IG', source: 'ads' } }

    before do
      allow(rules_relation).to receive(:find_by).with(account_id: 7, source_id: 'AD_IG').and_return(rule)
    end

    it 'injects team_id' do
      expect(apply[:team_id]).to eq(55)
    end
  end

  context 'when there is no active mapping' do
    let(:channel) { :whatsapp }
    let(:referral) { { source_id: 'UNMAPPED' } }

    it 'leaves conversation_params untouched' do
      expect(apply).not_to have_key(:team_id)
    end
  end

  context 'when the conversation is organic (no referral)' do
    let(:channel) { :whatsapp }
    let(:referral) { nil }

    it 'does nothing and never queries mappings' do
      expect(rules_relation).not_to receive(:find_by)
      expect(apply).not_to have_key(:team_id)
    end
  end

  context 'when the referral has no source_id' do
    let(:channel) { :whatsapp }
    let(:referral) { { source_type: 'ad' } }

    it 'does not inject a team_id' do
      expect(apply).not_to have_key(:team_id)
    end
  end

  context 'when conversation_params already has a team_id' do
    let(:channel) { :whatsapp }
    let(:referral) { { source_id: 'AD_123' } }
    let(:conversation_params) { { account_id: 7, team_id: 99 } }

    it 'does not override the existing team_id' do
      expect(rules_relation).not_to receive(:find_by)
      expect(apply[:team_id]).to eq(99)
    end
  end
end
