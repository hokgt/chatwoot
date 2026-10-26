# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 5 — the PURE, ADVISORY ShadowAcceptance gate. These examples feed it GENUINE,
# complete ShadowMetricsStore snapshots (the exact top-level shape + every recorder counter,
# arithmetically self-consistent) and pin: the exact conservative boundaries (49 vs 50 total, the
# comparable floor, 5% error, 10% decision-none, 80% agreement), zero-denominator safety, every
# conservation-law corruption folding to hold/inconsistent_counters, every forged/invalid snapshot
# shape folding to hold/invalid_snapshot, integer basis-point rates, all three statuses, and that
# it NEVER emits cutover / mutates anything. It reads ONLY the snapshot.
RSpec.describe Marine::Decision::ShadowAcceptance do
  # A GENUINE, complete counter set mirroring exactly how ShadowObservation/ShadowMetricsStore
  # increment counters: comparable == normalized, errors == total - comparable land in a real
  # non-normalized reason, one confidence/decision/legacy presence per sample, and the
  # agreement/disagreement + confusion-matrix cells sum to comparable.
  def counters_for(total:, comparable:, decision_none:, agreement:)
    {
      'total' => total,
      'reason.normalized' => comparable,
      'reason.timeout' => total - comparable,
      'confidence.high' => total,
      'decision_scenario.none' => decision_none,
      'decision_scenario.present' => total - decision_none,
      'legacy_scenario.present' => total,
      'comparable' => comparable,
      'agreement' => agreement,
      'disagreement' => comparable - agreement,
      'matrix.scenario_1.scenario_1' => agreement,
      'matrix.scenario_1.scenario_2' => comparable - agreement
    }
  end

  # Wrap counters in the EXACT genuine ShadowMetricsStore ok-snapshot top-level shape.
  def snapshot(counters)
    {
      schema_version: Marine::Decision::ShadowMetricsStore::SCHEMA_VERSION,
      ok: true,
      account_id: 1,
      assistant_id: 3,
      days: 14,
      counters: counters
    }
  end

  # A fully-passing baseline snapshot; individual examples override one dimension.
  def genuine(overrides = {})
    knobs = { total: 100, comparable: 100, decision_none: 0, agreement: 100 }.merge(overrides)
    snapshot(counters_for(**knobs))
  end

  def report_for(overrides = {})
    described_class.evaluate(genuine(overrides))
  end

  def status_for(overrides = {})
    report_for(overrides)[:status]
  end

  it 'is eligible_for_review when every conservative threshold is met' do
    report = report_for
    expect(report[:status]).to eq('eligible_for_review')
    expect(report[:reason]).to eq('thresholds_met')
  end

  describe 'sample-size boundaries (insufficient_data)' do
    it 'holds insufficient at 49 total but clears at 50' do
      expect(status_for(total: 49, comparable: 49, agreement: 49)).to eq('insufficient_data')
      expect(status_for(total: 50, comparable: 50, agreement: 50)).to eq('eligible_for_review')
    end

    it 'reports insufficient_comparable below the comparable floor and leaves insufficient_data at it' do
      below = genuine(total: 50, comparable: 29, agreement: 29)
      at = genuine(total: 50, comparable: 30, agreement: 30)
      expect(described_class.evaluate(below)).to include(status: 'insufficient_data', reason: 'insufficient_comparable')
      # At the floor the comparable gate is satisfied, so evaluation advances past insufficient_data
      # into the quality gates. (errors == total - comparable, so the fallback/error rate is the
      # binding quality gate here — the two are the same quantity by construction.)
      expect(described_class.evaluate(at)[:status]).not_to eq('insufficient_data')
    end
  end

  describe 'quality boundaries (hold)' do
    it 'clears at exactly 5% error but holds above it' do
      expect(status_for(total: 100, comparable: 95, agreement: 95)).to eq('eligible_for_review')
      report = described_class.evaluate(genuine(total: 100, comparable: 94, agreement: 94))
      expect(report[:status]).to eq('hold')
      expect(report[:reason]).to eq('error_rate_exceeded')
    end

    it 'clears at exactly 10% decision-scenario-none but holds above it' do
      expect(status_for(decision_none: 10)).to eq('eligible_for_review')
      report = described_class.evaluate(genuine(decision_none: 11))
      expect(report[:status]).to eq('hold')
      expect(report[:reason]).to eq('decision_none_rate_exceeded')
    end

    it 'clears at exactly 80% agreement but holds below it' do
      expect(status_for(agreement: 80)).to eq('eligible_for_review')
      report = described_class.evaluate(genuine(agreement: 79))
      expect(report[:status]).to eq('hold')
      expect(report[:reason]).to eq('agreement_below_threshold')
    end
  end

  describe 'divide-by-zero safety' do
    it 'is divide-by-zero safe with zero denominators (folds to insufficient)' do
      snap = genuine(total: 0, comparable: 0, decision_none: 0, agreement: 0)
      report = nil
      expect { report = described_class.evaluate(snap) }.not_to raise_error
      expect(report[:status]).to eq('insufficient_data')
      expect(report[:rates_bps]).to eq(error: 0, decision_scenario_none: 0, agreement: 0)
    end
  end

  describe 'conservation-law corruption (every case folds to hold/inconsistent_counters)' do
    # A genuine, self-consistent base; each example corrupts exactly one conservation law.
    def base_counters
      counters_for(total: 100, comparable: 100, decision_none: 0, agreement: 100)
    end

    {
      'reason family not summing to total' => { 'reason.timeout' => 5 },
      'confidence family not summing to total' => { 'confidence.high' => 90 },
      'decision presence not summing to total' => { 'decision_scenario.present' => 90 },
      'legacy presence not summing to total' => { 'legacy_scenario.present' => 90 },
      'comparable != normalized' => { 'reason.normalized' => 90, 'reason.timeout' => 10 },
      'comparable != agreement + disagreement' => { 'agreement' => 90 },
      'comparable != matrix sum' => { 'matrix.scenario_1.scenario_1' => 90 },
      'agreement exceeding comparable' => { 'agreement' => 110 },
      'comparable exceeding total' => { 'comparable' => 150 },
      'an intent counter exceeding total' => { 'intent.price' => 150 },
      'slot increments exceeding the per-observation cap' =>
        { 'slot.set.product' => 100, 'slot.set.variant_input' => 100, 'slot.replace.product' => 100 }
    }.each do |label, corruption|
      it "folds #{label} to hold/inconsistent_counters" do
        report = described_class.evaluate(snapshot(base_counters.merge(corruption)))
        expect(report[:status]).to eq('hold')
        expect(report[:reason]).to eq('inconsistent_counters')
      end
    end
  end

  describe 'forged / invalid snapshots (fail closed to hold/invalid_snapshot)' do
    def expect_invalid(snap)
      report = described_class.evaluate(snap)
      expect(report[:status]).to eq('hold')
      expect(report[:reason]).to eq('invalid_snapshot')
    end

    it 'folds a non-ok / non-hash / structurally-empty snapshot to hold/invalid_snapshot' do
      [{ ok: false, reason: 'read_error', counters: {} }, 'nope', { ok: true }, nil, 42].each { |snap| expect_invalid(snap) }
    end

    it 'rejects a wrong or missing schema_version' do
      expect_invalid(genuine.merge(schema_version: 'marine_decision_shadow_metrics_v2'))
      expect_invalid(genuine.except(:schema_version))
    end

    it 'rejects a non-positive / non-integer account or assistant id' do
      [{ account_id: 0 }, { account_id: -1 }, { account_id: '1' }, { assistant_id: 0 }, { assistant_id: nil }].each do |bad|
        expect_invalid(genuine.merge(bad))
      end
    end

    it 'rejects out-of-range or non-integer days' do
      [{ days: 0 }, { days: 15 }, { days: 3.0 }, { days: nil }].each { |bad| expect_invalid(genuine.merge(bad)) }
    end

    it 'rejects an extra top-level key (forged shape)' do
      expect_invalid(genuine.merge(extra: 'x'))
    end

    it 'rejects a missing required top-level key' do
      expect_invalid(genuine.except(:days))
    end

    it 'rejects a non-hash counters' do
      expect_invalid(genuine.merge(counters: []))
    end

    it 'folds a non-integer counter value to hold/invalid_snapshot' do
      snap = genuine
      snap[:counters] = snap[:counters].merge('total' => '100')
      expect_invalid(snap)
    end
  end

  describe 'report shape' do
    it 'reports integer basis-point rates and the fixed thresholds, deep-frozen' do
      report = described_class.evaluate(genuine(total: 100, comparable: 95, agreement: 76, decision_none: 5))
      expect(report[:rates_bps]).to eq(error: 500, decision_scenario_none: 500, agreement: 8000)
      expect(report[:thresholds]).to eq(
        min_total: 50, min_comparable: 30, max_error_bps: 500,
        max_decision_scenario_none_bps: 1_000, min_agreement_bps: 8_000
      )
      expect(report).to be_frozen
      expect(report[:rates_bps]).to be_frozen
    end

    it 'exposes the aggregate samples it evaluated' do
      report = described_class.evaluate(genuine(total: 100, comparable: 95, agreement: 76, decision_none: 5))
      expect(report[:samples]).to eq(total: 100, comparable: 95, errors: 5, decision_scenario_none: 5, agreement: 76)
    end

    it 'never emits cutover and only ever uses the closed status vocabulary' do
      %i[status reason].each { |field| expect(report_for[field]).not_to eq('cutover') }
      expect(status_for).to be_in(%w[insufficient_data hold eligible_for_review])
    end
  end
end
