# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 4 — the DEFAULT-OFF, read-only shadow configuration. These examples stub
# the underlying InstallationConfig read so no live config is touched, and pin: the flag is
# off by default and on ONLY for the exact true representation; and the assistant allowlist is
# bounded, strict, frozen, and fails the WHOLE list closed to [] on any anomaly — never raising
# or writing. Phase 1 (Opsi B): there is NO scenario-capability registry (execution authorization
# is backend-policy-owned). All scenario/intent strings are SYNTHETIC.
RSpec.describe Marine::Decision::ShadowConfig do
  def stub_read(enabled: nil, assistant_ids: nil)
    allow(Marine::Llm::Config).to receive(:installation_value).with(described_class::ENABLED_KEY).and_return(enabled.to_s)
    allow(Marine::Llm::Config).to receive(:installation_value)
      .with(described_class::ASSISTANT_IDS_KEY).and_return(assistant_ids.to_s)
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

  it 'does not expose a scenario-capability consumer (Phase 1 / Opsi B — backend-policy-owned authz)' do
    expect(described_class).not_to respond_to(:scenario_capabilities)
    expect(described_class.const_defined?(:CAPABILITIES_KEY)).to be(false)
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

      it 'with more ids than the bound' do
        oversized = (1..(described_class::MAX_ASSISTANT_IDS + 1)).to_a
        stub_read(assistant_ids: JSON.generate(oversized))
        expect(described_class.assistant_allowlist).to eq([])
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
    it 'is true only when globally enabled AND the id is in a valid non-empty allowlist' do
      stub_read(enabled: 'true', assistant_ids: JSON.generate([3, 7]))
      expect(described_class.enabled_for?(3)).to be(true)
      expect(described_class.enabled_for?(7)).to be(true)
    end

    it 'is false for an id not present in the allowlist' do
      stub_read(enabled: 'true', assistant_ids: JSON.generate([3, 7]))
      expect(described_class.enabled_for?(9)).to be(false)
    end

    it 'is false whenever the global flag is off, regardless of the allowlist' do
      stub_read(enabled: 'false', assistant_ids: JSON.generate([3]))
      expect(described_class.enabled_for?(3)).to be(false)
    end

    it 'is false for a missing/empty allowlist even when globally enabled' do
      stub_read(enabled: 'true', assistant_ids: nil)
      expect(described_class.enabled_for?(3)).to be(false)
      stub_read(enabled: 'true', assistant_ids: '[]')
      expect(described_class.enabled_for?(3)).to be(false)
    end

    it 'is false for a malformed allowlist even when globally enabled' do
      stub_read(enabled: 'true', assistant_ids: '["3"]')
      expect(described_class.enabled_for?(3)).to be(false)
    end

    it 'is false for a non-positive-integer id argument' do
      stub_read(enabled: 'true', assistant_ids: JSON.generate([3]))
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
