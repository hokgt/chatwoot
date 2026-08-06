# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/meta_ads_team_routing/routing_rule')

RSpec.describe Wijaya::MetaAdsTeamRoutingRule do
  let(:account) { create(:account) }
  let(:team) { create(:team, account: account) }

  def build_rule(attrs = {})
    described_class.new({ account: account, team: team, source_id: 'AD_123' }.merge(attrs))
  end

  it 'is valid with a source_id, team and account' do
    expect(build_rule).to be_valid
  end

  it 'requires a source_id' do
    rule = build_rule(source_id: nil)
    expect(rule).not_to be_valid
    expect(rule.errors[:source_id]).to be_present
  end

  it 'enforces source_id uniqueness per account' do
    build_rule.save!
    duplicate = build_rule
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:source_id]).to be_present
  end

  it 'allows the same source_id across different accounts' do
    build_rule.save!
    other_account = create(:account)
    other_team = create(:team, account: other_account)
    other_rule = described_class.new(account: other_account, team: other_team, source_id: 'AD_123')
    expect(other_rule).to be_valid
  end

  it 'validates that the team belongs to the same account' do
    foreign_team = create(:team, account: create(:account))
    rule = build_rule(team: foreign_team)
    expect(rule).not_to be_valid
    expect(rule.errors[:team]).to be_present
  end

  it 'defaults to active and exposes the active scope' do
    active_rule = build_rule.tap(&:save!)
    inactive_rule = build_rule(source_id: 'AD_999', status: :inactive).tap(&:save!)

    expect(active_rule).to be_active
    expect(described_class.active).to include(active_rule)
    expect(described_class.active).not_to include(inactive_rule)
  end
end
