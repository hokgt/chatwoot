# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 4 — the DEFAULT-OFF, read-only shadow configuration. These examples stub
# the underlying InstallationConfig read so no live config is touched, and pin: the flag is
# off by default and on ONLY for the exact true representation; and the capability registry
# is bounded, allowlisted, canonically-ordered, frozen, and fails the WHOLE map closed to
# {} on any anomaly — never raising or writing. All scenario/intent strings are SYNTHETIC.
RSpec.describe Marine::Decision::ShadowConfig do
  def stub_read(enabled: nil, capabilities: nil)
    allow(Marine::Llm::Config).to receive(:installation_value).with(described_class::ENABLED_KEY).and_return(enabled.to_s)
    allow(Marine::Llm::Config).to receive(:installation_value)
      .with(described_class::CAPABILITIES_KEY).and_return(capabilities.to_s)
  end

  describe '.enabled?' do
    it 'is off by default (unset / blank value)' do
      stub_read(enabled: nil)
      expect(described_class.enabled?).to be(false)
    end

    it 'is on ONLY for the exact true representation' do
      stub_read(enabled: 'true')
      expect(described_class.enabled?).to be(true)
    end

    it 'stays off for near-true or truthy-looking values' do
      ['TRUE', 'True', '1', 'yes', 'on', ' true ', 'false', 'enabled'].each do |value|
        stub_read(enabled: value)
        expect(described_class.enabled?).to be(false)
      end
    end

    it 'never raises when the read fails' do
      allow(Marine::Llm::Config).to receive(:installation_value).and_raise(StandardError, 'boom')
      expect(described_class.enabled?).to be(false)
    end
  end

  describe '.scenario_capabilities' do
    it 'returns a frozen, canonically-ordered allowlisted map for a valid config' do
      stub_read(capabilities: JSON.generate('scenario_7' => %w[stock price], 'scenario_12' => ['catalog']))
      result = described_class.scenario_capabilities

      # Canonical Schema::INTENTS order (price precedes stock) regardless of input order.
      expect(result).to eq('scenario_7' => %w[price stock], 'scenario_12' => %w[catalog])
      expect(result).to be_frozen
      expect(result['scenario_7']).to be_frozen
    end

    it 'accepts an explicit empty capability array' do
      stub_read(capabilities: JSON.generate('scenario_7' => []))
      expect(described_class.scenario_capabilities).to eq('scenario_7' => [])
    end

    it 'allows the unsupported bucket as a capability' do
      stub_read(capabilities: JSON.generate('scenario_9' => %w[unsupported]))
      expect(described_class.scenario_capabilities).to eq('scenario_9' => %w[unsupported])
    end

    it 'defaults to {} when unset' do
      stub_read(capabilities: nil)
      expect(described_class.scenario_capabilities).to eq({})
    end

    context 'when the config is anomalous (fails the WHOLE map closed to {})' do
      {
        'malformed JSON' => 'not json {',
        'a non-object root (array)' => '["stock"]',
        'a non-object root (scalar)' => '42',
        'an unknown intent' => '{"scenario_1":["teleport"]}',
        'a duplicate intent' => '{"scenario_1":["stock","stock"]}',
        'a non-array value' => '{"scenario_1":"stock"}',
        'a non-string capability' => '{"scenario_1":[1]}',
        'a title-derived (non scenario_<id>) key' => '{"Stock Check":["stock"]}',
        'an uppercase key' => '{"SCENARIO_1":["stock"]}',
        'a non-numeric id key' => '{"scenario_abc":["stock"]}'
      }.each do |label, raw|
        it "with #{label}" do
          stub_read(capabilities: raw)
          expect(described_class.scenario_capabilities).to eq({})
        end
      end

      it 'with a duplicate scenario key (allow_duplicate_key: false)' do
        stub_read(capabilities: '{"scenario_1":["stock"],"scenario_1":["price"]}')
        expect(described_class.scenario_capabilities).to eq({})
      end

      it 'with an oversize payload' do
        stub_read(capabilities: 'x' * (described_class::MAX_CONFIG_BYTES + 1))
        expect(described_class.scenario_capabilities).to eq({})
      end

      it 'with more scenario keys than the bound' do
        oversized = (0..described_class::MAX_SCENARIOS).to_h { |i| ["scenario_#{i}", ['stock']] }
        stub_read(capabilities: JSON.generate(oversized))
        expect(described_class.scenario_capabilities).to eq({})
      end

      it 'with more capabilities than the per-scenario bound' do
        too_many = Array.new(described_class::MAX_CAPABILITIES_PER_SCENARIO + 1) { 'stock' }
        stub_read(capabilities: JSON.generate('scenario_1' => too_many))
        expect(described_class.scenario_capabilities).to eq({})
      end
    end

    it 'never raises even when the read itself raises' do
      allow(Marine::Llm::Config).to receive(:installation_value).and_raise(StandardError, 'boom')
      expect(described_class.scenario_capabilities).to eq({})
    end
  end
end
