# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/core/hooks')
require Rails.root.join('custom/wijaya/batteries/meta_ads_team_routing/hooks')

# Regression coverage for the native channel-builder integration surface: the single
# Wijaya::Batteries::Core::Hooks.dispatch(:meta_ads_team_routing, :apply_team_routing!, ...)
# call placed immediately before Conversation.create!. The contract is that it RETURNS an
# isolated params hash with team_id injected when a rule matches (the caller reassigns its
# params variable to the return value), and NEVER mutates the caller's original hash. On any
# failure — a missing routing-rules table, a disabled battery, a hook that mutates its own
# private duplicate then raises — the dispatcher returns the untouched original object, so the
# native builder proceeds with exactly the params it produced.
RSpec.describe 'Meta Ads team routing dispatch (native-hook fail-open)' do
  subject(:dispatch) do
    Wijaya::Batteries::Core::Hooks.dispatch(
      :meta_ads_team_routing, :apply_team_routing!,
      default: conversation_params,
      account: account, inbox: inbox, channel: :whatsapp,
      referral: referral, conversation_params: conversation_params
    )
  end

  let(:account) { instance_double(Account, id: 7, blank?: false) }
  let(:inbox) { instance_double(Inbox) }
  let(:conversation_params) { { account_id: 7, inbox_id: 3 } }
  let(:rules_relation) { instance_double(ActiveRecord::Relation) }

  before do
    allow(Wijaya::MetaAdsTeamRoutingRule).to receive(:active).and_return(rules_relation)
    allow(rules_relation).to receive(:find_by).and_return(nil)
  end

  context 'when a referral maps to an active rule' do
    let(:referral) { { source_id: 'AD_123', source_type: 'ad' } }
    let(:rule) { instance_double(Wijaya::MetaAdsTeamRoutingRule, team_id: 55) }

    before do
      allow(rules_relation).to receive(:find_by).with(account_id: 7, source_id: 'AD_123').and_return(rule)
    end

    it 'returns a NEW hash carrying team_id and leaves the original conversation_params exactly unchanged' do
      original_snapshot = conversation_params.dup

      result = dispatch

      expect(result[:team_id]).to eq(55)
      # A different object is returned; the caller's original hash is not the routed one.
      expect(result).not_to equal(conversation_params)
      expect(conversation_params).to eq(original_snapshot)
      expect(conversation_params).not_to have_key(:team_id)
    end
  end

  context 'when there is no active rule (organic / unmapped)' do
    let(:referral) { { source_id: 'UNMAPPED' } }

    it 'returns params without team_id and leaves the original conversation_params unchanged' do
      original_snapshot = conversation_params.dup

      expect(dispatch).not_to have_key(:team_id)
      expect(conversation_params).to eq(original_snapshot)
    end
  end

  context 'when the conversation already has a team assigned' do
    let(:referral) { { source_id: 'AD_123' } }
    let(:conversation_params) { { account_id: 7, inbox_id: 3, team_id: 100 } }

    before do
      allow(rules_relation).to receive(:find_by).and_return(instance_double(Wijaya::MetaAdsTeamRoutingRule, team_id: 55))
    end

    it 'never overrides the already-set team_id' do
      expect(dispatch[:team_id]).to eq(100)
    end
  end

  context 'when the hook mutates its own private duplicate and then raises' do
    let(:referral) { { source_id: 'AD_123' } }

    before do
      # Simulate a service boundary that partially mutates a private copy before failing.
      allow(Wijaya::Batteries::MetaAdsTeamRouting::Hooks).to receive(:apply_team_routing!) do |**kwargs|
        private_dup = kwargs[:conversation_params].dup
        private_dup[:team_id] = 999
        raise ActiveRecord::StatementInvalid, 'boom after partial mutation'
      end
    end

    it 'returns the original object unchanged (the default), never the partially mutated dup' do
      original = conversation_params

      result = dispatch

      expect(result).to equal(original)
      expect(original).not_to have_key(:team_id)
    end
  end

  context 'when the routing-rules table is missing / the query raises' do
    let(:referral) { { source_id: 'AD_123' } }

    before do
      allow(Wijaya::MetaAdsTeamRoutingRule).to receive(:active)
        .and_raise(ActiveRecord::StatementInvalid.new('PG::UndefinedTable'))
    end

    it 'fails open: never raises and leaves conversation_params unchanged' do
      result = nil
      expect { result = dispatch }.not_to raise_error
      expect(result).to eq({ account_id: 7, inbox_id: 3 })
    end
  end

  context 'when the battery module cannot be resolved (disabled/absent)' do
    let(:referral) { { source_id: 'AD_123' } }

    before do
      stub_const(
        'Wijaya::Batteries::Core::Hooks::FEATURE_HOOK_MODULES',
        { meta_ads_team_routing: 'No::Such::Battery::Module' }
      )
    end

    it 'fails open to the untouched native params' do
      expect(dispatch).to eq({ account_id: 7, inbox_id: 3 })
    end
  end
end
