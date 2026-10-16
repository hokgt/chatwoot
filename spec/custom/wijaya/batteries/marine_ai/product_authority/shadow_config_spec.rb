# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the DEFAULT-OFF, strictly read-only PRODUCT AUTHORITY shadow configuration. It reads
# ONLY four MARINE_PRODUCT_AUTHORITY_* InstallationConfig keys (never a MARINE_DECISION_* key), never
# writes/memoizes/raises/touches Redis, and every read is fresh. These examples stub the underlying
# InstallationConfig read so no live config is touched, and pin: the shadow flag is on ONLY for the
# exact trimmed 'true'; rollback is on ONLY for exact 'true' and folds to true (engaged) on a read
# error; shadow_enabled_for? requires a positive Integer id + rollback off + flag on + allowlisted id;
# the allowlist fails the WHOLE list closed on any anomaly; candidate_mode_for stays 'off' unless the
# shadow is enabled for the id AND the value is a known mode. All ids/values are SYNTHETIC.
RSpec.describe Marine::ProductAuthority::ShadowConfig do
  def stub_read(shadow_enabled: nil, assistant_ids: nil, candidate_mode: nil, rollback: nil)
    stub_key(described_class::SHADOW_ENABLED_KEY, shadow_enabled)
    stub_key(described_class::ASSISTANT_IDS_KEY, assistant_ids)
    stub_key(described_class::CANDIDATE_MODE_KEY, candidate_mode)
    stub_key(described_class::ROLLBACK_KEY, rollback)
  end

  def stub_key(key, value)
    allow(Marine::Llm::Config).to receive(:installation_value).with(key).and_return(value.to_s)
  end

  it 'reads the four product-authority keys (never a MARINE_DECISION_* key)' do
    keys = [described_class::SHADOW_ENABLED_KEY, described_class::ASSISTANT_IDS_KEY,
            described_class::CANDIDATE_MODE_KEY, described_class::ROLLBACK_KEY]
    expect(keys).to all(start_with('MARINE_PRODUCT_AUTHORITY_'))
  end

  describe '.shadow_enabled?' do
    it 'is on ONLY for the exact trimmed true' do
      stub_read(shadow_enabled: 'true')
      expect(described_class.shadow_enabled?).to be(true)
    end

    it 'is off for blank / near-true / truthy-looking values' do
      [nil, '', 'false', '1', 'TRUE', 'True', ' true ', 'yes', 'on'].each do |value|
        stub_read(shadow_enabled: value)
        expect(described_class.shadow_enabled?).to be(false)
      end
    end

    it 'folds to false when the read raises' do
      allow(Marine::Llm::Config).to receive(:installation_value).and_raise(StandardError, 'boom')
      expect(described_class.shadow_enabled?).to be(false)
    end
  end

  describe '.rollback?' do
    it 'is engaged ONLY for the exact trimmed true' do
      stub_read(rollback: 'true')
      expect(described_class.rollback?).to be(true)
    end

    it 'is off for blank / near-true values' do
      [nil, '', 'false', '1', 'TRUE'].each do |value|
        stub_read(rollback: value)
        expect(described_class.rollback?).to be(false)
      end
    end

    it 'folds to true (rollback engaged = safest) when the read raises' do
      allow(Marine::Llm::Config).to receive(:installation_value).and_raise(StandardError, 'boom')
      expect(described_class.rollback?).to be(true)
    end
  end

  describe '.shadow_enabled_for?' do
    it 'is true ONLY for a positive Integer id with rollback off, the flag on, and the id allowlisted' do
      stub_read(shadow_enabled: 'true', assistant_ids: JSON.generate([3, 7]))
      expect(described_class.shadow_enabled_for?(3)).to be(true)
      expect(described_class.shadow_enabled_for?(7)).to be(true)
    end

    it 'is false for an id not in the allowlist' do
      stub_read(shadow_enabled: 'true', assistant_ids: JSON.generate([3]))
      expect(described_class.shadow_enabled_for?(9)).to be(false)
    end

    it 'is false when the flag is off even with an allowlisted id' do
      stub_read(shadow_enabled: 'false', assistant_ids: JSON.generate([3]))
      expect(described_class.shadow_enabled_for?(3)).to be(false)
    end

    it 'is false when rollback is engaged even with flag on + id allowlisted' do
      stub_read(shadow_enabled: 'true', assistant_ids: JSON.generate([3]), rollback: 'true')
      expect(described_class.shadow_enabled_for?(3)).to be(false)
    end

    it 'is false for a non-positive-integer id argument' do
      stub_read(shadow_enabled: 'true', assistant_ids: JSON.generate([3]))
      [nil, 0, -3, '3', 3.0].each { |bad| expect(described_class.shadow_enabled_for?(bad)).to be(false) }
    end

    it 'folds to false when the read raises' do
      allow(Marine::Llm::Config).to receive(:installation_value).and_raise(StandardError, 'boom')
      expect(described_class.shadow_enabled_for?(3)).to be(false)
    end
  end

  describe '.assistant_allowlist' do
    it 'returns the exact unique positive integer ids, frozen, for a valid list' do
      stub_read(assistant_ids: JSON.generate([3, 7, 12]))
      result = described_class.assistant_allowlist
      expect(result).to eq([3, 7, 12])
      expect(result).to be_frozen
    end

    context 'when the list is anomalous (fails the WHOLE list closed to [])' do
      {
        'blank' => '',
        'malformed JSON' => 'not json [',
        'a non-array root (object)' => '{"3":true}',
        'a non-array root (scalar)' => '3',
        'a string id' => '["3"]',
        'a float id' => '[3.0]',
        'a boolean id' => '[true]',
        'a zero id' => '[0]',
        'a negative id' => '[-3]',
        'a duplicate id' => '[3,3]'
      }.each do |label, raw|
        it "with #{label}" do
          stub_read(assistant_ids: raw)
          expect(described_class.assistant_allowlist).to eq([])
        end
      end

      it 'with more ids than the bound (>50)' do
        stub_read(assistant_ids: JSON.generate((1..(described_class::MAX_ASSISTANT_IDS + 1)).to_a))
        expect(described_class.assistant_allowlist).to eq([])
      end

      it 'with an id above the bigint ceiling' do
        stub_read(assistant_ids: JSON.generate([described_class::MAX_ASSISTANT_ID + 1]))
        expect(described_class.assistant_allowlist).to eq([])
      end
    end

    it 'folds to [] when the read raises' do
      allow(Marine::Llm::Config).to receive(:installation_value).and_raise(StandardError, 'boom')
      expect(described_class.assistant_allowlist).to eq([])
    end
  end

  describe '.candidate_mode_for' do
    it 'returns the staged shadow mode when the shadow is enabled for the id and the value is a known mode' do
      stub_read(shadow_enabled: 'true', assistant_ids: JSON.generate([3]), candidate_mode: 'shadow')
      expect(described_class.candidate_mode_for(3)).to eq('shadow')
    end

    it 'returns off when the value is the off mode' do
      stub_read(shadow_enabled: 'true', assistant_ids: JSON.generate([3]), candidate_mode: 'off')
      expect(described_class.candidate_mode_for(3)).to eq('off')
    end

    it 'returns off for an unknown / blank mode value even when enabled' do
      ['staged', 'live', '', nil].each do |value|
        stub_read(shadow_enabled: 'true', assistant_ids: JSON.generate([3]), candidate_mode: value)
        expect(described_class.candidate_mode_for(3)).to eq('off')
      end
    end

    it 'returns off when the shadow is not enabled for the id even if the value is shadow' do
      stub_read(shadow_enabled: 'true', assistant_ids: JSON.generate([3]), candidate_mode: 'shadow')
      expect(described_class.candidate_mode_for(9)).to eq('off')
    end

    it 'returns off when rollback is engaged even if the value is shadow' do
      stub_read(shadow_enabled: 'true', assistant_ids: JSON.generate([3]), candidate_mode: 'shadow', rollback: 'true')
      expect(described_class.candidate_mode_for(3)).to eq('off')
    end

    it 'folds to off when the read raises' do
      allow(Marine::Llm::Config).to receive(:installation_value).and_raise(StandardError, 'boom')
      expect(described_class.candidate_mode_for(3)).to eq('off')
    end
  end
end
