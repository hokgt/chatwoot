# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 6 — the BACKEND-AUTHORITATIVE scenario resolver. These examples use persisted
# records so the re-query against assistant.scenarios.enabled runs for real, and pin: only the exact
# `scenario_<positive integer>` key resolves; a wrong format, a zero / negative / out-of-range id, a
# missing / disabled / cross-assistant row, or any error yields nil; and the row is re-queried at
# resolution time (never trusted from the key), so disabling a scenario stops resolving it.
RSpec.describe Marine::Decision::ScenarioResolver do
  let(:account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }

  def scenario(enabled: true, **attrs)
    create(:marine_scenario, assistant: assistant, account: account, enabled: enabled,
                             title: attrs[:title] || 'Stock', description: 'Check stock levels',
                             instruction: 'Answer stock questions')
  end

  it 'resolves the exact stable key to the enabled scenario for this assistant' do
    record = scenario
    expect(described_class.new(assistant: assistant).resolve("scenario_#{record.id}")).to eq(record)
  end

  it 'returns nil for a disabled scenario' do
    record = scenario(enabled: false)
    expect(described_class.new(assistant: assistant).resolve("scenario_#{record.id}")).to be_nil
  end

  it 'returns nil for a missing id' do
    expect(described_class.new(assistant: assistant).resolve('scenario_999999')).to be_nil
  end

  it 'returns nil for a scenario belonging to another assistant (cross-assistant)' do
    other = create(:marine_assistant, account: account)
    foreign = create(:marine_scenario, assistant: other, account: account,
                                       title: 'Other', description: 'Other desc', instruction: 'Other inst')
    expect(described_class.new(assistant: assistant).resolve("scenario_#{foreign.id}")).to be_nil
  end

  describe 'wrong key format => nil' do
    ['scenario_0', 'scenario_07', 'scenario_-3', 'scenario_abc', 'scenario_', 'scenario_1.0',
     'SCENARIO_1', 'scenario-1', ' scenario_1', 'scenario_1 ', 'foo_1', '1', '', 'scenario_1_2'].each do |key|
      it "returns nil for #{key.inspect}" do
        # A real enabled scenario exists, yet a non-canonical key never resolves.
        scenario
        expect(described_class.new(assistant: assistant).resolve(key)).to be_nil
      end
    end

    it 'returns nil for a non-string key' do
      [nil, 123, :scenario_1, { key: 'scenario_1' }].each do |key|
        expect(described_class.new(assistant: assistant).resolve(key)).to be_nil
      end
    end
  end

  it 'returns nil for an out-of-range (above bigint) id' do
    over = described_class::MAX_ID + 1
    expect(described_class.new(assistant: assistant).resolve("scenario_#{over}")).to be_nil
  end

  it 're-queries at resolution time: a scenario disabled after the key was minted no longer resolves' do
    record = scenario
    resolver = described_class.new(assistant: assistant)
    key = "scenario_#{record.id}"
    expect(resolver.resolve(key)).to eq(record)

    record.update!(enabled: false)
    expect(resolver.resolve(key)).to be_nil
  end

  it 'returns nil (never raises) for an assistant that does not expose scenarios' do
    expect(described_class.new(assistant: double('no_scenarios')).resolve('scenario_1')).to be_nil
  end

  it 'returns nil (never raises) when the scenario query itself raises' do
    broken = double('assistant')
    allow(broken).to receive(:respond_to?).with(:scenarios).and_return(true)
    allow(broken).to receive(:scenarios).and_raise(StandardError, 'db down')
    expect(described_class.new(assistant: broken).resolve('scenario_1')).to be_nil
  end
end
