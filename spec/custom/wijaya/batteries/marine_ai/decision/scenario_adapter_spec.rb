# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 4 — the read-only ScenarioAdapter. These examples drive the adapter with
# scenario doubles + a stubbed capability registry (no DB write) and pin: enabled-only,
# id-ordered scenarios; the stable `scenario_<id>` key (never title-derived); capabilities
# sourced ONLY from the explicit registry (never inferred from title/description/instruction);
# bounded, owned text; and that it mutates nothing. All scenario strings are SYNTHETIC.
RSpec.describe Marine::Decision::ScenarioAdapter do
  subject(:adapter) { described_class.new(assistant: assistant) }

  let(:assistant) { double('assistant') }
  let(:relation) { double('scenarios_relation') }

  def scenario(id, description: 'availability', instruction: 'check stock')
    double("scenario_#{id}", id: id, description: description, instruction: instruction)
  end

  def stub_scenarios(list)
    allow(assistant).to receive(:scenarios).and_return(relation)
    allow(relation).to receive_messages(enabled: relation, order: relation, limit: relation, to_a: list)
  end

  before { allow(Marine::Decision::ShadowConfig).to receive(:scenario_capabilities).and_return({}) }

  it 'maps enabled scenarios to the stable scenario_<id> contract shape' do
    stub_scenarios([scenario(7), scenario(12)])
    result = adapter.scenarios

    expect(result.map { |s| s['key'] }).to eq(%w[scenario_7 scenario_12])
    expect(result.first).to eq('key' => 'scenario_7', 'description' => 'availability',
                               'instruction' => 'check stock', 'capabilities' => [])
  end

  it 'derives the key from the database id ONLY (never the title)' do
    allow(Marine::Decision::ShadowConfig).to receive(:scenario_capabilities)
      .and_return('scenario_5' => %w[price])
    stub_scenarios([scenario(5, description: 'Fancy Vase Stock', instruction: 'look up availability')])

    entry = adapter.scenarios.first
    expect(entry['key']).to eq('scenario_5')
    # Capability came from the registry keyed by scenario_5, NOT inferred from the text.
    expect(entry['capabilities']).to eq(%w[price])
  end

  it 'gives a scenario with no registry entry an empty capability list' do
    allow(Marine::Decision::ShadowConfig).to receive(:scenario_capabilities).and_return('scenario_99' => %w[stock])
    stub_scenarios([scenario(7)])
    expect(adapter.scenarios.first['capabilities']).to eq([])
  end

  it 'bounds description/instruction to the contract summary ceiling' do
    stub_scenarios([scenario(1, description: 'd' * 5_000, instruction: 'i' * 5_000)])
    entry = adapter.scenarios.first
    expect(entry['description'].length).to eq(described_class::MAX_TEXT_CHARS)
    expect(entry['instruction'].length).to eq(described_class::MAX_TEXT_CHARS)
  end

  it 'returns owned data (fresh strings/arrays), not frozen registry values' do
    frozen_caps = { 'scenario_1' => %w[stock].freeze }.freeze
    allow(Marine::Decision::ShadowConfig).to receive(:scenario_capabilities).and_return(frozen_caps)
    stub_scenarios([scenario(1)])

    caps = adapter.scenarios.first['capabilities']
    expect(caps).to eq(%w[stock])
    expect { caps << 'price' }.not_to raise_error # owned, mutable copy
  end

  it 'returns [] when the assistant exposes no scenarios association' do
    bare = double('assistant_without_scenarios')
    expect(described_class.new(assistant: bare).scenarios).to eq([])
  end

  describe 'overflow detection (bounded MAX_SCENARIOS + 1 fetch)' do
    def scenarios_of(count)
      (1..count).map { |id| scenario(id) }
    end

    it 'fetches at most MAX_SCENARIOS + 1 rows so a huge set is never loaded in full' do
      allow(assistant).to receive(:scenarios).and_return(relation)
      allow(relation).to receive_messages(enabled: relation, order: relation, to_a: [])
      expect(relation).to receive(:limit).with(described_class::MAX_SCENARIOS + 1).and_return(relation)

      described_class.new(assistant: assistant).overflow?
    end

    it 'is not overflow at exactly MAX_SCENARIOS and exposes the complete set' do
      stub_scenarios(scenarios_of(described_class::MAX_SCENARIOS))
      adapter = described_class.new(assistant: assistant)

      expect(adapter.overflow?).to be(false)
      expect(adapter.scenarios.length).to eq(described_class::MAX_SCENARIOS)
    end

    it 'is overflow once the fetch returns MAX_SCENARIOS + 1 rows' do
      stub_scenarios(scenarios_of(described_class::MAX_SCENARIOS + 1))
      expect(described_class.new(assistant: assistant).overflow?).to be(true)
    end
  end
end
