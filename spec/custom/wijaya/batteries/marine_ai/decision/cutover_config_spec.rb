# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 6 — the STRICT, fail-closed cutover configuration. These examples stub the
# underlying InstallationConfig read (via Marine::Llm::Config.installation_value) so no live config
# is touched, and pin: the flags are off by default and on ONLY for the EXACT trimmed 'true';
# rollback has the HIGHEST precedence and forces closed; the assistant allowlist is a bounded JSON
# array of unique positive integers that fails the WHOLE list closed to [] on any anomaly; and
# enabled_for? additionally requires the EXISTING ShadowConfig.enabled_for? so a cut-over assistant
# always remains under the live shadow + allowlist. All ids are synthetic; nothing writes or raises.
RSpec.describe Marine::Decision::CutoverConfig do
  def stub_read(enabled: nil, rollback: nil, assistant_ids: nil, shadow_enabled: nil, shadow_ids: nil)
    {
      described_class::ENABLED_KEY => enabled,
      described_class::ROLLBACK_KEY => rollback,
      described_class::ASSISTANT_IDS_KEY => assistant_ids,
      Marine::Decision::ShadowConfig::ENABLED_KEY => shadow_enabled,
      Marine::Decision::ShadowConfig::ASSISTANT_IDS_KEY => shadow_ids,
      Marine::Decision::ShadowConfig::CAPABILITIES_KEY => ''
    }.each do |key, value|
      allow(Marine::Llm::Config).to receive(:installation_value).with(key).and_return(value.to_s)
    end
  end

  # Everything valid for the given id: cutover enabled + id allowlisted, shadow enabled + id
  # allowlisted, rollback off. Individual examples override exactly one dimension.
  def all_valid(id: 3, **overrides)
    defaults = { enabled: 'true', rollback: nil, assistant_ids: JSON.generate([id]),
                 shadow_enabled: 'true', shadow_ids: JSON.generate([id]) }
    stub_read(**defaults, **overrides)
  end

  describe '.enabled?' do
    it 'is off by default (unset / blank value)' do
      stub_read(enabled: nil)
      expect(described_class.enabled?).to be(false)
    end

    it 'is on for the exact trimmed true representation' do
      stub_read(enabled: 'true')
      expect(described_class.enabled?).to be(true)
      stub_read(enabled: ' true ')
      expect(described_class.enabled?).to be(true)
    end

    it 'stays off for near-true or truthy-looking values' do
      %w[TRUE True 1 yes on false enabled truee].each do |value|
        stub_read(enabled: value)
        expect(described_class.enabled?).to be(false)
      end
    end

    it 'never raises when the read fails' do
      allow(Marine::Llm::Config).to receive(:installation_value).and_raise(StandardError, 'boom')
      expect(described_class.enabled?).to be(false)
    end
  end

  describe '.rollback?' do
    it 'is off by default' do
      stub_read(rollback: nil)
      expect(described_class.rollback?).to be(false)
    end

    it 'is on ONLY for the exact trimmed true representation' do
      stub_read(rollback: 'true')
      expect(described_class.rollback?).to be(true)
      stub_read(rollback: ' true ')
      expect(described_class.rollback?).to be(true)
    end

    it 'stays off for near-true values' do
      %w[TRUE 1 yes false].each do |value|
        stub_read(rollback: value)
        expect(described_class.rollback?).to be(false)
      end
    end

    it 'fails closed to rollback ENGAGED (true) when the read raises' do
      allow(Marine::Llm::Config).to receive(:installation_value).and_raise(StandardError, 'boom')
      expect(described_class.rollback?).to be(true)
    end
  end

  describe '.assistant_allowlist' do
    it 'returns the exact unique positive integer ids for a valid list' do
      stub_read(assistant_ids: JSON.generate([3, 7, 12]))
      result = described_class.assistant_allowlist
      expect(result).to eq([3, 7, 12])
      expect(result).to be_frozen
    end

    it 'defaults to [] when unset' do
      stub_read(assistant_ids: nil)
      expect(described_class.assistant_allowlist).to eq([])
    end

    context 'when the list is anomalous (fails the WHOLE list closed to [])' do
      {
        'malformed JSON' => 'not json [',
        'a non-array root (object)' => '{"3":true}',
        'a non-array root (scalar)' => '3',
        'a string id' => '["3"]',
        'a float id' => '[3.0]',
        'a boolean id' => '[true]',
        'a null id' => '[null]',
        'a zero id' => '[0]',
        'a negative id' => '[-3]',
        'a duplicate id' => '[3,3]',
        'a nested array' => '[[3]]'
      }.each do |label, raw|
        it "with #{label}" do
          stub_read(assistant_ids: raw)
          expect(described_class.assistant_allowlist).to eq([])
        end
      end

      it 'with an oversize payload' do
        stub_read(assistant_ids: 'x' * (described_class::MAX_CONFIG_BYTES + 1))
        expect(described_class.assistant_allowlist).to eq([])
      end

      it 'with more ids than the bound (50)' do
        oversized = (1..(described_class::MAX_ASSISTANT_IDS + 1)).to_a
        stub_read(assistant_ids: JSON.generate(oversized))
        expect(described_class.assistant_allowlist).to eq([])
      end

      it 'accepts exactly the bound of ids' do
        exactly = (1..described_class::MAX_ASSISTANT_IDS).to_a
        stub_read(assistant_ids: JSON.generate(exactly))
        expect(described_class.assistant_allowlist).to eq(exactly)
      end

      it 'with an id above the bigint ceiling' do
        stub_read(assistant_ids: JSON.generate([described_class::MAX_ASSISTANT_ID + 1]))
        expect(described_class.assistant_allowlist).to eq([])
      end
    end

    it 'never raises when the read itself raises' do
      allow(Marine::Llm::Config).to receive(:installation_value).and_raise(StandardError, 'boom')
      expect(described_class.assistant_allowlist).to eq([])
    end
  end

  describe '.enabled_for?' do
    it 'is true only when cutover enabled + allowlisted AND shadow enabled + allowlisted, no rollback' do
      all_valid(id: 3)
      expect(described_class.enabled_for?(3)).to be(true)
    end

    it 'is forced CLOSED by rollback even when everything else is valid (highest precedence)' do
      all_valid(id: 3, rollback: 'true')
      expect(described_class.enabled_for?(3)).to be(false)
    end

    it 'is false when the cutover flag is off' do
      all_valid(id: 3, enabled: 'false')
      expect(described_class.enabled_for?(3)).to be(false)
    end

    it 'is false for an id not in the cutover allowlist' do
      all_valid(id: 3)
      expect(described_class.enabled_for?(9)).to be(false)
    end

    it 'is false for a missing/empty cutover allowlist even when enabled' do
      all_valid(id: 3, assistant_ids: nil)
      expect(described_class.enabled_for?(3)).to be(false)
      all_valid(id: 3, assistant_ids: '[]')
      expect(described_class.enabled_for?(3)).to be(false)
    end

    it 'is false for a malformed cutover allowlist even when enabled' do
      all_valid(id: 3, assistant_ids: '["3"]')
      expect(described_class.enabled_for?(3)).to be(false)
    end

    it 'is false when the SHADOW flag is off (cross-shadow gating keeps observation active)' do
      all_valid(id: 3, shadow_enabled: 'false')
      expect(described_class.enabled_for?(3)).to be(false)
    end

    it 'is false when the id is not in the SHADOW allowlist (cross-shadow gating)' do
      all_valid(id: 3, shadow_ids: JSON.generate([99]))
      expect(described_class.enabled_for?(3)).to be(false)
    end

    it 'is false for a non-positive-integer id argument' do
      all_valid(id: 3)
      [nil, 0, -3, '3', 3.0].each do |bad|
        expect(described_class.enabled_for?(bad)).to be(false)
      end
    end

    it 'never raises when the read fails' do
      allow(Marine::Llm::Config).to receive(:installation_value).and_raise(StandardError, 'boom')
      expect(described_class.enabled_for?(3)).to be(false)
    end
  end
end
