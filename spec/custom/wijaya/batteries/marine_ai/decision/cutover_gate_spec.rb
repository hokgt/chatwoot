# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 6 — the READ-ONLY, fail-closed cutover authority gate. These examples inject the
# config / metrics store / acceptance dependencies so nothing touches live config or Redis, and pin:
# the gate opens ONLY when the config is open for the assistant AND the advisory acceptance report is
# EXACTLY eligible_for_review / thresholds_met; every other outcome (hold, insufficient, invalid,
# malformed, error) closes it; a closed config means the metrics snapshot is NEVER read (immediate
# rollback); and the snapshot is read over the fixed 14-day window. It never writes or auto-enables.
RSpec.describe Marine::Decision::CutoverGate do
  subject(:gate) { described_class.new(config: config, store: store, acceptance: acceptance) }

  let(:config) { class_double(Marine::Decision::CutoverConfig) }
  let(:store) { class_double(Marine::Decision::ShadowMetricsStore) }
  let(:acceptance) { class_double(Marine::Decision::ShadowAcceptance) }

  def report(status:, reason:)
    { status: status, reason: reason }
  end

  before do
    allow(config).to receive(:enabled_for?).and_return(true)
    allow(store).to receive(:snapshot).and_return(:snapshot)
    allow(acceptance).to receive(:evaluate).and_return(
      report(status: Marine::Decision::ShadowAcceptance::STATUS_ELIGIBLE, reason: 'thresholds_met')
    )
  end

  it 'opens ONLY on the exact eligible_for_review / thresholds_met report' do
    expect(gate.open?(account_id: 1, assistant_id: 3)).to be(true)
  end

  it 'reads the metrics snapshot over the fixed 14-day window for the scoped ids' do
    gate.open?(account_id: 1, assistant_id: 3)
    expect(store).to have_received(:snapshot).with(account_id: 1, assistant_id: 3, days: 14)
  end

  describe 'closes on any non-eligible acceptance outcome' do
    {
      'hold' => { status: 'hold', reason: 'agreement_below_threshold' },
      'insufficient_data' => { status: 'insufficient_data', reason: 'insufficient_total' },
      'invalid_snapshot' => { status: 'hold', reason: 'invalid_snapshot' },
      'eligible status but wrong reason' => { status: 'eligible_for_review', reason: 'something_else' },
      'right reason but non-eligible status' => { status: 'hold', reason: 'thresholds_met' }
    }.each do |label, verdict|
      it "with #{label}" do
        allow(acceptance).to receive(:evaluate).and_return(report(**verdict))
        expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
      end
    end

    it 'with a malformed (non-hash) report' do
      allow(acceptance).to receive(:evaluate).and_return('not a hash')
      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
    end
  end

  describe 'config-closed short circuit' do
    it 'is closed and NEVER reads the metrics snapshot when the config is closed for the assistant' do
      allow(config).to receive(:enabled_for?).and_return(false)

      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
      expect(store).not_to have_received(:snapshot)
      expect(acceptance).not_to have_received(:evaluate)
    end
  end

  describe 'invalid scope' do
    it 'is closed for a non-positive account/assistant id and never reads config or metrics' do
      [[0, 3], [1, 0], [nil, 3], [1, -1], ['1', 3]].each do |account_id, assistant_id|
        expect(gate.open?(account_id: account_id, assistant_id: assistant_id)).to be(false)
      end
      expect(config).not_to have_received(:enabled_for?)
      expect(store).not_to have_received(:snapshot)
    end
  end

  describe 'fail-closed on dependency errors' do
    it 'closes when the metrics store raises' do
      allow(store).to receive(:snapshot).and_raise(StandardError, 'redis down')
      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
    end

    it 'closes when acceptance raises' do
      allow(acceptance).to receive(:evaluate).and_raise(StandardError, 'boom')
      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
    end

    it 'closes when the config check raises' do
      allow(config).to receive(:enabled_for?).and_raise(StandardError, 'boom')
      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
    end
  end

  # Prove the gate opens on a GENUINELY eligible report by driving the REAL ShadowAcceptance over a
  # hand-built genuine metrics snapshot (only the store is injected), and closes on a held one.
  describe 'with the real ShadowAcceptance over a genuine snapshot' do
    subject(:gate) { described_class.new(config: config, store: store, acceptance: Marine::Decision::ShadowAcceptance) }

    def counters(total:, comparable:, agreement:)
      {
        'total' => total, 'reason.normalized' => comparable, 'reason.timeout' => total - comparable,
        'confidence.high' => total, 'decision_scenario.none' => 0, 'decision_scenario.present' => total,
        'legacy_scenario.present' => total, 'comparable' => comparable, 'agreement' => agreement,
        'disagreement' => comparable - agreement, 'matrix.scenario_1.scenario_1' => agreement,
        'matrix.scenario_1.scenario_2' => comparable - agreement
      }
    end

    def snapshot(counters)
      { schema_version: Marine::Decision::ShadowMetricsStore::SCHEMA_VERSION, ok: true,
        account_id: 1, assistant_id: 3, days: 14, counters: counters }
    end

    it 'opens on a genuinely eligible snapshot' do
      allow(store).to receive(:snapshot).and_return(snapshot(counters(total: 100, comparable: 100, agreement: 100)))
      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(true)
    end

    it 'closes on a genuine snapshot that only holds (agreement below threshold)' do
      allow(store).to receive(:snapshot).and_return(snapshot(counters(total: 100, comparable: 100, agreement: 50)))
      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
    end

    it 'closes on a genuine but insufficient snapshot' do
      allow(store).to receive(:snapshot).and_return(snapshot(counters(total: 10, comparable: 10, agreement: 10)))
      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
    end
  end

  it 'only ever consults read-only dependencies (config check, snapshot read, acceptance evaluate)' do
    gate.open?(account_id: 1, assistant_id: 3)
    expect(config).to have_received(:enabled_for?).with(3).once
    expect(store).to have_received(:snapshot).once
    expect(acceptance).to have_received(:evaluate).once
  end
end
