# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the PRIVACY-SAFE, immutable ShadowObservation of ONE product-authority shadow comparison.
# It is built ONLY from a deep-frozen ShadowExecution result ({ legacy:, candidate:, comparable: }) plus
# the account/assistant ids and exposes ONLY aggregate-safe, allowlisted codes. These examples pin: it
# reads the two closed ProductOutcome hashes + the agreement flags; it raises Invalid (no partial trust)
# on any malformed input; it is frozen with frozen members; and it carries NO raw id / text / value —
# only the given account/assistant ids and closed vocabulary codes. All inputs are SYNTHETIC.
RSpec.describe Marine::ProductAuthority::ShadowObservation do
  def outcome(status: 'product', intents: %w[price], slot_ops: %w[product], requires_exact_variant: false, quantity_inquiry: false)
    { status: status, intents: intents, slot_ops: slot_ops,
      requires_exact_variant: requires_exact_variant, quantity_inquiry: quantity_inquiry }
  end

  def build(legacy: outcome, candidate: outcome, comparable: true, account_id: 1, assistant_id: 3)
    described_class.build(result: { legacy: legacy, candidate: candidate, comparable: comparable },
                          account_id: account_id, assistant_id: assistant_id)
  end

  describe 'a valid comparison' do
    it 'exposes the scope ids and the closed status/intent/slot/quantity codes' do
      obs = build(legacy: outcome(status: 'product', intents: %w[price], slot_ops: %w[product], quantity_inquiry: true),
                  candidate: outcome(status: 'overview', intents: %w[product_overview], slot_ops: %w[variant_code]))
      expect(obs.account_id).to eq(1)
      expect(obs.assistant_id).to eq(3)
      expect(obs.legacy_status).to eq('product')
      expect(obs.candidate_status).to eq('overview')
      expect(obs.legacy_intents).to eq(%w[price])
      expect(obs.candidate_intents).to eq(%w[product_overview])
      expect(obs.legacy_slot_ops).to eq(%w[product])
      expect(obs.candidate_slot_ops).to eq(%w[variant_code])
      expect(obs.legacy_quantity_inquiry?).to be(true)
      expect(obs.candidate_quantity_inquiry?).to be(false)
    end

    it 'reports comparable? and the exact/intent/slot/status agreement flags' do
      matched = build
      expect(matched.comparable?).to be(true)
      expect(matched.exact_match?).to be(true)
      expect(matched.intents_match?).to be(true)
      expect(matched.slots_match?).to be(true)
      expect(matched.status_match?).to be(true)
    end

    it 'reports a disagreement when legacy and candidate outcomes differ' do
      obs = build(candidate: outcome(status: 'unsupported', intents: [], slot_ops: []))
      expect(obs.exact_match?).to be(false)
      expect(obs.status_match?).to be(false)
      expect(obs.intents_match?).to be(false)
    end

    it 'carries the comparable flag from the result' do
      expect(build(comparable: false).comparable?).to be(false)
      expect(build(comparable: 'yes').comparable?).to be(false)
    end
  end

  describe 'privacy — carries no raw ids / text / values' do
    it 'exposes only the given scope ids and closed codes (no raw accessors)' do
      obs = build
      %i[trigger history message_id conversation_id inbox_id contact_id
         raw_candidate customer_language family variant price stock].each do |forbidden|
        expect(obs).not_to respond_to(forbidden)
      end
      expect(obs.legacy.keys.sort).to eq(described_class::OUTCOME_KEYS.sort)
      expect(obs.candidate.keys.sort).to eq(described_class::OUTCOME_KEYS.sort)
    end
  end

  describe 'deep-frozen + owned members' do
    it 'is frozen with frozen outcome members' do
      obs = build
      expect(obs).to be_frozen
      expect(obs.legacy).to be_frozen
      expect(obs.candidate).to be_frozen
      expect(obs.legacy_intents).to be_frozen
      expect(obs.legacy_slot_ops).to be_frozen
    end
  end

  describe 'fail-closed rejection (no partial trust)' do
    it 'raises Invalid for a non-hash result' do
      expect { described_class.build(result: [], account_id: 1, assistant_id: 3) }.to raise_error(described_class::Invalid)
    end

    it 'raises Invalid when an outcome side is missing / not a hash' do
      expect { build(legacy: nil) }.to raise_error(described_class::Invalid)
      expect { build(candidate: 'nope') }.to raise_error(described_class::Invalid)
    end

    it 'raises Invalid for an outcome missing a contract key' do
      expect { build(legacy: { status: 'product', intents: [], slot_ops: [] }) }.to raise_error(described_class::Invalid)
    end

    it 'raises Invalid for an out-of-vocabulary status' do
      expect { build(legacy: outcome(status: 'weird')) }.to raise_error(described_class::Invalid)
    end

    it 'raises Invalid for an unknown or duplicate intent code' do
      expect { build(legacy: outcome(intents: %w[teleport])) }.to raise_error(described_class::Invalid)
      expect { build(legacy: outcome(intents: %w[price price])) }.to raise_error(described_class::Invalid)
    end

    it 'raises Invalid for an unknown or duplicate slot code' do
      expect { build(legacy: outcome(slot_ops: %w[warehouse])) }.to raise_error(described_class::Invalid)
      expect { build(legacy: outcome(slot_ops: %w[product product])) }.to raise_error(described_class::Invalid)
    end

    it 'raises Invalid for a non-boolean flag' do
      expect { build(legacy: outcome(quantity_inquiry: 'yes')) }.to raise_error(described_class::Invalid)
      expect { build(legacy: outcome(requires_exact_variant: 1)) }.to raise_error(described_class::Invalid)
    end

    it 'raises Invalid for a non-positive / non-integer scope id' do
      expect { build(account_id: 0) }.to raise_error(described_class::Invalid)
      expect { build(assistant_id: '3') }.to raise_error(described_class::Invalid)
    end
  end
end
