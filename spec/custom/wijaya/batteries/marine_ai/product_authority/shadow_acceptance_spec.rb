# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the PURE, ADVISORY ShadowAcceptance gate over the product-authority shadow metrics. These
# examples feed it GENUINE, complete ShadowMetricsStore ok-snapshots (the exact top-level shape + every
# recorder conservation law satisfied) PLUS a separately-supplied, validated mutation-proof artifact,
# and pin: the exact conservative boundaries in integer basis points (8000 bps agreement, 2000 bps
# blocked), the sample-size floors (50 total / 30 comparable), every conservation-law corruption
# folding to hold/inconsistent_counters, every forged shape folding to hold/invalid_snapshot, a
# missing/malformed mutation proof folding to hold/mutation_proof_missing, a proof that claims a
# mutation folding to hold/mutation_detected, a FORGED runtime snapshot that cannot assert zero
# mutation, all three statuses, and that it NEVER emits cutover. All ids/counters are SYNTHETIC.
RSpec.describe Marine::ProductAuthority::ShadowAcceptance do
  # The validated mutation-proof artifact the Evaluator produces; acceptance requires it to reach
  # eligible (the runtime snapshot deliberately makes NO self-declared mutation claim).
  def valid_proof
    { schema_version: described_class::MUTATION_PROOF_SCHEMA, source: 'evaluator', runs: 20, mutation_observed: false }
  end

  # A GENUINE counter set honouring every conservation law the recorder guarantees.
  def counters_for(total:, comparable:, exact_agreement:, blocked: 0)
    {
      'total' => total,
      'legacy_status.product' => total,
      'candidate_status.product' => total - blocked,
      'candidate_status.blocked' => blocked,
      'comparable' => comparable,
      'exact_agreement' => exact_agreement,
      'matrix.product.product' => comparable
    }
  end

  def snapshot(counters, overrides = {})
    { schema_version: Marine::ProductAuthority::ShadowMetricsStore::SCHEMA_VERSION, ok: true, account_id: 1, assistant_id: 3,
      days: 14, counters: counters }.merge(overrides)
  end

  def genuine(overrides = {})
    knobs = { total: 100, comparable: 100, exact_agreement: 100, blocked: 0 }.merge(overrides)
    snapshot(counters_for(**knobs))
  end

  def evaluate(snap, proof: valid_proof)
    described_class.evaluate(snap, mutation_proof: proof)
  end

  def status_for(overrides = {})
    evaluate(genuine(overrides))[:status]
  end

  it 'is eligible_for_review / thresholds_met when every conservative threshold is met' do
    report = evaluate(genuine)
    expect(report[:status]).to eq('eligible_for_review')
    expect(report[:reason]).to eq('thresholds_met')
  end

  describe 'sample-size floors (insufficient_data)' do
    it 'holds insufficient below MIN_TOTAL but clears at it' do
      below = genuine(total: 49, comparable: 30, exact_agreement: 30)
      at = genuine(total: 50, comparable: 50, exact_agreement: 50)
      expect(evaluate(below)).to include(status: 'insufficient_data', reason: 'insufficient_total')
      expect(evaluate(at)[:status]).to eq('eligible_for_review')
    end

    it 'reports insufficient_comparable below the comparable floor' do
      below = genuine(total: 50, comparable: 29, exact_agreement: 29)
      expect(evaluate(below)).to include(status: 'insufficient_data', reason: 'insufficient_comparable')
    end
  end

  describe 'exact-agreement basis-point boundary (8000 bps)' do
    it 'passes at exactly 8000 bps and holds at 7999 bps' do
      pass = genuine(total: 10_000, comparable: 10_000, exact_agreement: 8_000)
      fail_snap = genuine(total: 10_000, comparable: 10_000, exact_agreement: 7_999)
      expect(evaluate(pass)[:status]).to eq('eligible_for_review')
      report = evaluate(fail_snap)
      expect(report[:status]).to eq('hold')
      expect(report[:reason]).to eq('exact_agreement_below_threshold')
    end
  end

  describe 'candidate-blocked basis-point boundary (2000 bps)' do
    it 'passes at exactly 2000 bps and holds at 2001 bps' do
      pass = genuine(total: 10_000, comparable: 10_000, exact_agreement: 10_000, blocked: 2_000)
      fail_snap = genuine(total: 10_000, comparable: 10_000, exact_agreement: 10_000, blocked: 2_001)
      expect(evaluate(pass)[:status]).to eq('eligible_for_review')
      report = evaluate(fail_snap)
      expect(report[:status]).to eq('hold')
      expect(report[:reason]).to eq('candidate_blocked_rate_exceeded')
    end
  end

  describe 'mutation proof (separately supplied, validated artifact)' do
    it 'folds a missing proof to hold/mutation_proof_missing' do
      report = described_class.evaluate(genuine, mutation_proof: nil)
      expect(report[:status]).to eq('hold')
      expect(report[:reason]).to eq('mutation_proof_missing')
    end

    it 'folds a malformed proof to hold/mutation_proof_missing' do
      [
        valid_proof.merge(schema_version: 'nope'),
        valid_proof.merge(source: 'forged'),
        valid_proof.merge(runs: 0),
        valid_proof.merge(extra: 'x'),
        valid_proof.except(:runs),
        'not-a-hash'
      ].each do |bad|
        expect(described_class.evaluate(genuine, mutation_proof: bad)[:reason]).to eq('mutation_proof_missing')
      end
    end

    it 'folds a proof that claims an observed mutation to hold/mutation_detected' do
      report = described_class.evaluate(genuine, mutation_proof: valid_proof.merge(mutation_observed: true))
      expect(report[:status]).to eq('hold')
      expect(report[:reason]).to eq('mutation_detected')
    end

    it 'a FORGED runtime snapshot cannot assert zero mutation' do
      # Re-adding a self-declared mutations field is now a forged shape (extra top-level key) and,
      # even without it, a snapshot alone can never reach eligible without the external proof.
      expect(described_class.evaluate(genuine.merge(mutations: 0), mutation_proof: valid_proof)[:reason]).to eq('invalid_snapshot')
      expect(described_class.evaluate(genuine)[:reason]).to eq('mutation_proof_missing')
    end
  end

  describe 'conservation-law corruption (folds to hold/inconsistent_counters)' do
    def corrupt(counter_override)
      base = counters_for(total: 100, comparable: 100, exact_agreement: 100, blocked: 0)
      evaluate(snapshot(base.merge(counter_override)))
    end

    {
      'legacy_status family not summing to total' => { 'legacy_status.product' => 90 },
      'candidate_status family not summing to total' => { 'candidate_status.product' => 90 },
      'matrix sum != comparable' => { 'matrix.product.product' => 90 },
      'comparable exceeding total' => { 'comparable' => 150 }
    }.each do |label, corruption|
      it "folds #{label} to hold/inconsistent_counters" do
        report = corrupt(corruption)
        expect(report[:status]).to eq('hold')
        expect(report[:reason]).to eq('inconsistent_counters')
      end
    end
  end

  describe 'forged / invalid snapshots (fold to hold/invalid_snapshot)' do
    def expect_invalid(snap)
      report = evaluate(snap)
      expect(report[:status]).to eq('hold')
      expect(report[:reason]).to eq('invalid_snapshot')
    end

    it 'folds a non-hash / ok:false / structurally-empty snapshot' do
      ['nope', nil, 42, { ok: false, reason: 'read_error', counters: {} }, { ok: true }].each { |snap| expect_invalid(snap) }
    end

    it 'rejects a wrong or missing schema_version' do
      expect_invalid(genuine.merge(schema_version: 'marine_product_authority_shadow_metrics_v2'))
      expect_invalid(genuine.except(:schema_version))
    end

    it 'rejects a missing required top-level key' do
      expect_invalid(genuine.except(:days))
    end

    it 'rejects an extra top-level key (forged shape)' do
      expect_invalid(genuine.merge(extra: 'x'))
    end

    it 'rejects a non-positive / non-integer scope id or out-of-range days' do
      [{ account_id: 0 }, { assistant_id: '3' }, { days: 0 }, { days: 15 }].each { |bad| expect_invalid(genuine.merge(bad)) }
    end
  end

  describe 'closed status vocabulary' do
    it 'never emits cutover and only ever uses the closed status set' do
      %i[status reason].each { |field| expect(evaluate(genuine)[field]).not_to eq('cutover') }
      expect(status_for).to be_in(%w[insufficient_data hold eligible_for_review])
    end
  end
end
