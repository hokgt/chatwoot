# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 5 — the PRIVACY-SAFE, immutable ShadowObservation. These examples build it
# from a synthetic Stage 4 result and pin: it exposes ONLY aggregate-safe allowlisted codes,
# strips every raw/forbidden field (customer_language, slot raw_candidate/candidate_type),
# rejects any malformed input fail-closed, is deep-frozen, and owns its members (a later
# mutation of the input never leaks in). All scenario/intent strings are SYNTHETIC.
RSpec.describe Marine::Decision::ShadowObservation do
  # rubocop:disable Metrics/ParameterLists
  def plan(reason: 'normalized', key: 'scenario_7', confidence: 'high',
           intents: %w[price stock], slots: default_slots, language: 'id')
    {
      schema_version: 'marine_decision_v1',
      scenario_candidate: { key: key, confidence: confidence },
      intents: intents,
      slot_operations: slots,
      customer_language: language,
      confidence: confidence,
      reason: reason
    }
  end

  def default_slots
    [{ operation: 'set', slot: 'product', value: { raw_candidate: 'Secret Widget Name', candidate_type: 'display_name' } }]
  end
  # rubocop:enable Metrics/ParameterLists

  def build(result_overrides = {}, account_id: 1, assistant_id: 3)
    result = { legacy_scenario_key: 'scenario_7', candidate_plan: plan }.merge(result_overrides)
    described_class.build(result: result, account_id: account_id, assistant_id: assistant_id)
  end

  describe 'a valid comparison' do
    it 'exposes only aggregate-safe allowlisted codes' do
      obs = build
      expect(obs.account_id).to eq(1)
      expect(obs.assistant_id).to eq(3)
      expect(obs.legacy_key).to eq('scenario_7')
      expect(obs.decision_key).to eq('scenario_7')
      expect(obs.reason).to eq('normalized')
      expect(obs.confidence).to eq('high')
      expect(obs.intents).to eq(%w[price stock])
      expect(obs.slot_pairs).to eq([%w[set product]])
    end

    it 'marks comparable + matching when the decision normalized and the keys agree' do
      obs = build
      expect(obs.comparable?).to be(true)
      expect(obs.match?).to be(true)
      expect(obs.legacy_present?).to be(true)
      expect(obs.decision_present?).to be(true)
    end

    it 'is not comparable for a fallback (non-normalized) plan' do
      obs = build({ candidate_plan: plan(reason: 'timeout', key: nil, intents: [], slots: []) })
      expect(obs.comparable?).to be(false)
      expect(obs.decision_present?).to be(false)
    end

    it 'is a mismatch when the two stable keys differ' do
      obs = build({ candidate_plan: plan(key: 'scenario_12') })
      expect(obs.match?).to be(false)
    end

    it 'treats a nil legacy key as none' do
      obs = build({ legacy_scenario_key: nil })
      expect(obs.legacy_key).to be_nil
      expect(obs.legacy_present?).to be(false)
    end
  end

  describe 'privacy — forbidden/raw fields never surface' do
    it 'exposes no raw slot candidate value or candidate_type and no customer_language accessor' do
      obs = build
      expect(obs.slot_pairs.flatten).not_to include('Secret Widget Name', 'display_name')
      %i[customer_language raw_candidate candidate_type trigger history message_id conversation_id].each do |forbidden|
        expect(obs).not_to respond_to(forbidden)
      end
    end
  end

  describe 'deep-frozen + input ownership' do
    it 'is frozen with frozen members' do
      obs = build
      expect(obs).to be_frozen
      expect(obs.intents).to be_frozen
      expect(obs.slot_pairs).to be_frozen
      expect(obs.slot_pairs.first).to be_frozen
      expect(obs.legacy_key).to be_frozen
    end

    it 'owns its members — a later mutation of the input never leaks in' do
      intents = %w[price stock]
      result = { legacy_scenario_key: 'scenario_7', candidate_plan: plan(intents: intents) }
      obs = described_class.build(result: result, account_id: 1, assistant_id: 3)
      intents << 'catalog'
      expect(obs.intents).to eq(%w[price stock])
    end
  end

  describe 'canonicality hardening (exact schema + no duplicates)' do
    it 'rejects a missing schema_version' do
      p = plan
      p.delete(:schema_version)
      expect { described_class.build(result: { legacy_scenario_key: 'scenario_7', candidate_plan: p }, account_id: 1, assistant_id: 3) }
        .to raise_error(described_class::Invalid)
    end

    it 'rejects a wrong schema_version' do
      expect { build({ candidate_plan: plan.merge(schema_version: 'marine_decision_v2') }) }
        .to raise_error(described_class::Invalid)
    end

    it 'rejects duplicate intents (a canonical plan dedupes them)' do
      expect { build({ candidate_plan: plan(intents: %w[price price]) }) }
        .to raise_error(described_class::Invalid)
    end

    it 'rejects two operations targeting the same slot (duplicate target / pair)' do
      dup = [{ operation: 'set', slot: 'product', value: { raw_candidate: 'A', candidate_type: 'display_name' } },
             { operation: 'clear', slot: 'product', value: nil }]
      expect { build({ candidate_plan: plan(slots: dup) }) }.to raise_error(described_class::Invalid)
    end

    it 'accepts distinct slot targets' do
      distinct = [{ operation: 'set', slot: 'product', value: { raw_candidate: 'A', candidate_type: 'display_name' } },
                  { operation: 'set', slot: 'variant_input', value: { raw_candidate: 'B', candidate_type: 'variant_code' } }]
      obs = build({ candidate_plan: plan(slots: distinct) })
      expect(obs.slot_pairs).to eq([%w[set product], %w[set variant_input]])
    end
  end

  describe 'fail-closed rejection (no partial trust)' do
    it 'rejects a non-hash result' do
      expect { described_class.build(result: [], account_id: 1, assistant_id: 3) }
        .to raise_error(described_class::Invalid)
    end

    it 'rejects a non-hash candidate plan' do
      expect { build({ candidate_plan: 'nope' }) }.to raise_error(described_class::Invalid)
    end

    {
      'a non-positive account id' => { account_id: 0 },
      'a non-integer assistant id' => { assistant_id: '3' }
    }.each do |label, overrides|
      it "rejects #{label} in the ids" do
        expect { build({}, **overrides) }.to raise_error(described_class::Invalid)
      end
    end

    {
      'a non-canonical legacy key' => { legacy_scenario_key: 'Stock Check' },
      'a non-scenario_<id> decision key' => { candidate_plan_key: 'stock_check' },
      'an out-of-contract reason' => { reason: 'ok' },
      'an out-of-contract confidence' => { confidence: 'certain' },
      'an unknown intent' => { intents: %w[teleport] },
      'too many intents' => { intents: %w[price stock catalog parent_info variant_info] },
      'a bad slot operation' => { slots: [{ operation: 'destroy', slot: 'product', value: nil }] },
      'a bad slot name' => { slots: [{ operation: 'clear', slot: 'warehouse', value: nil }] }
    }.each do |label, opts|
      it "rejects #{label}" do
        result =
          if opts.key?(:legacy_scenario_key)
            { legacy_scenario_key: opts[:legacy_scenario_key], candidate_plan: plan }
          else
            key = opts.fetch(:candidate_plan_key, 'scenario_7')
            { legacy_scenario_key: 'scenario_7',
              candidate_plan: plan(key: key,
                                   reason: opts.fetch(:reason, 'normalized'),
                                   confidence: opts.fetch(:confidence, 'high'),
                                   intents: opts.fetch(:intents, %w[price]),
                                   slots: opts.fetch(:slots, [])) }
          end
        expect { described_class.build(result: result, account_id: 1, assistant_id: 3) }
          .to raise_error(described_class::Invalid)
      end
    end
  end
end
