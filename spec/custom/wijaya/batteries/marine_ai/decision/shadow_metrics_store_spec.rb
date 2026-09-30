# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 5 — the PRIVACY-SAFE Redis ShadowMetricsStore. Redis is fully stubbed (no live
# connection) and these examples pin: #record writes the exact UTC daily key, the exact bounded
# counters, and the 14-day TTL in ONE MULTI (no raw candidate/message/conversation id or text);
# a Redis failure returns false without raising; and #snapshot reads ONLY the explicit <=14
# daily keys (never a scan), merges non-negative integer counters, fails closed on a malformed
# field/value/cardinality, and returns a deep-frozen snapshot. All ids/keys are SYNTHETIC.
# A minimal fake MULTI transaction capturing the hincrby/expire calls (uniquely named so it
# never collides with another spec's helper when the suite loads together).
class MarineShadowFakeMulti
  attr_reader :incrs, :expiries

  def initialize
    @incrs = []
    @expiries = []
  end

  def hincrby(key, field, increment)
    @incrs << [key, field, increment]
  end

  def expire(key, seconds)
    @expiries << [key, seconds]
  end
end

RSpec.describe Marine::Decision::ShadowMetricsStore do
  let(:transaction) { MarineShadowFakeMulti.new }
  let(:conn) { double('conn') }

  def stub_multi
    allow(Redis::Alfred).to receive(:with).and_yield(conn)
    allow(conn).to receive(:multi).and_yield(transaction)
  end

  # rubocop:disable Metrics/ParameterLists
  def observation(reason: 'normalized', legacy_key: 'scenario_7', decision_key: 'scenario_7',
                  confidence: 'high', intents: %w[price stock],
                  slots: [{ operation: 'set', slot: 'product', value: { raw_candidate: 'X', candidate_type: 'display_name' } }])
    plan = {
      schema_version: 'marine_decision_v1',
      scenario_candidate: { key: decision_key, confidence: confidence },
      intents: intents, slot_operations: slots, customer_language: 'id',
      confidence: confidence, reason: reason
    }
    Marine::Decision::ShadowObservation.build(
      result: { legacy_scenario_key: legacy_key, candidate_plan: plan }, account_id: 1, assistant_id: 3
    )
  end
  # rubocop:enable Metrics/ParameterLists

  def fields_for(obs, now: Time.utc(2026, 9, 30, 23, 30))
    stub_multi
    described_class.new.record(obs, now: now)
    transaction.incrs
  end

  describe '#record' do
    it 'writes the exact daily key, counters, and 14-day TTL in one MULTI for a matching comparable turn' do
      stub_multi
      expect(described_class.new.record(observation, now: Time.utc(2026, 9, 30, 23, 30))).to be(true)

      key = 'marine:decision:shadow:metrics:v1:1:3:20260930'
      expect(transaction.incrs.map(&:first).uniq).to eq([key])
      expect(transaction.incrs.map(&:last).uniq).to eq([1])
      fields = transaction.incrs.map { |_, field, _incr| field }
      expect(fields).to contain_exactly(
        'total', 'reason.normalized', 'confidence.high',
        'decision_scenario.present', 'legacy_scenario.present',
        'intent.price', 'intent.stock', 'slot.set.product',
        'comparable', 'agreement', 'matrix.scenario_7.scenario_7'
      )
      expect(transaction.expiries).to eq([[key, described_class::TTL_SECONDS]])
    end

    it 'records disagreement + a none legacy side + the confusion cell when the keys differ' do
      fields = fields_for(observation(legacy_key: nil, decision_key: 'scenario_7', intents: [], slots: [])).map { |_, f, _| f }
      expect(fields).to contain_exactly(
        'total', 'reason.normalized', 'confidence.high',
        'decision_scenario.present', 'legacy_scenario.none',
        'comparable', 'disagreement', 'matrix.none.scenario_7'
      )
    end

    it 'records an unknown (non-comparable) turn with no comparable/agreement/matrix cell' do
      fields = fields_for(observation(reason: 'timeout', decision_key: nil, confidence: 'low', intents: [], slots: [])).map { |_, f, _| f }
      expect(fields).to contain_exactly(
        'total', 'reason.timeout', 'confidence.low',
        'decision_scenario.none', 'legacy_scenario.present'
      )
    end

    it 'never emits a raw candidate value, candidate_type, or a per-message identifier as a field' do
      fields = fields_for(observation).map { |_, f, _| f }
      expect(fields.join(' ')).not_to match(/display_name|message|conversation|contact|inbox/)
    end

    it 'returns false (never raises) when Redis fails' do
      allow(Redis::Alfred).to receive(:with).and_raise(StandardError, 'redis down')
      expect { expect(described_class.new.record(observation)).to be(false) }.not_to raise_error
    end

    it 'returns false without writing when a field component is out of contract' do
      bad = double('observation', account_id: 1, assistant_id: 3, reason: 'normalized', confidence: 'high',
                                  decision_present?: true, legacy_present?: true, intents: [], slot_pairs: [],
                                  comparable?: true, match?: false, legacy_key: 'not a key', decision_key: 'scenario_7')
      expect(Redis::Alfred).not_to receive(:with)
      expect(described_class.new.record(bad)).to be(false)
    end
  end

  describe '#snapshot' do
    def stub_pipeline(hashes)
      allow(Redis::Alfred).to receive(:with).and_yield(conn)
      pipeline = double('pipeline')
      @hgetall_keys = []
      allow(pipeline).to receive(:hgetall) { |key| @hgetall_keys << key }
      allow(conn).to receive(:pipelined) do |&blk|
        blk.call(pipeline)
        hashes
      end
    end

    it 'reads exactly the explicit last-N daily keys (no scan) and merges integer counters' do
      stub_pipeline([{ 'total' => '2', 'agreement' => '2' }, { 'total' => '3', 'disagreement' => '1' }, {}])
      expect(Redis::Alfred).not_to receive(:scan_each)
      expect(Redis::Alfred).not_to receive(:keys_count)

      snap = described_class.new.snapshot(account_id: 1, assistant_id: 3, days: 3, now: Time.utc(2026, 9, 30, 12))
      expect(@hgetall_keys).to eq(%w[
                                    marine:decision:shadow:metrics:v1:1:3:20260930
                                    marine:decision:shadow:metrics:v1:1:3:20260929
                                    marine:decision:shadow:metrics:v1:1:3:20260928
                                  ])
      expect(snap[:ok]).to be(true)
      expect(snap[:counters]).to eq('total' => 5, 'agreement' => 2, 'disagreement' => 1)
      expect(snap).to be_frozen
      expect(snap[:counters]).to be_frozen
    end

    it 'caps the window at 14 keys' do
      stub_pipeline([])
      described_class.new.snapshot(account_id: 1, assistant_id: 3, days: 14, now: Time.utc(2026, 9, 30, 12))
      expect(@hgetall_keys.length).to eq(14)
    end

    it 'fails closed to an error snapshot on an unknown field' do
      stub_pipeline([{ 'total' => '2', 'evil.field' => '1' }])
      snap = described_class.new.snapshot(account_id: 1, assistant_id: 3, days: 1, now: Time.utc(2026, 9, 30, 12))
      expect(snap).to include(ok: false, reason: 'invalid_counters', counters: {})
      expect(snap).to be_frozen
    end

    it 'fails closed on a non-integer / negative value' do
      ['1.5', '-3', 'nope', ''].each do |bad|
        stub_pipeline([{ 'total' => bad }])
        snap = described_class.new.snapshot(account_id: 1, assistant_id: 3, days: 1, now: Time.utc(2026, 9, 30, 12))
        expect(snap[:ok]).to be(false)
      end
    end

    it 'fails closed when the merged field cardinality is exceeded' do
      oversized = (0..described_class::MAX_FIELDS).to_h { |i| ["matrix.scenario_#{i}.scenario_1", '1'] }
      stub_pipeline([oversized])
      snap = described_class.new.snapshot(account_id: 1, assistant_id: 3, days: 1, now: Time.utc(2026, 9, 30, 12))
      expect(snap[:ok]).to be(false)
    end

    it 'rejects an invalid id / days / time as invalid_input without reading Redis' do
      expect(Redis::Alfred).not_to receive(:with)
      [{ account_id: 0 }, { assistant_id: -1 }, { days: 0 }, { days: 15 }, { now: 'nope' }].each do |bad|
        args = { account_id: 1, assistant_id: 3, days: 1, now: Time.utc(2026, 9, 30, 12) }.merge(bad)
        snap = described_class.new.snapshot(**args)
        expect(snap).to include(ok: false, reason: 'invalid_input')
      end
    end

    it 'returns a safe read_error snapshot when Redis raises' do
      allow(Redis::Alfred).to receive(:with).and_raise(StandardError, 'redis down')
      snap = described_class.new.snapshot(account_id: 1, assistant_id: 3, days: 1, now: Time.utc(2026, 9, 30, 12))
      expect(snap).to include(ok: false, reason: 'read_error', counters: {})
      expect(snap).to be_frozen
    end
  end

  describe 'privacy / no side effects (source proof)' do
    it 'persists no customer text / raw slot value / per-message identifier and no reply/routing/state/cutover/config write' do
      dir = Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/decision')
      code = %w[shadow_observation shadow_metrics_store shadow_acceptance]
             .map { |name| File.read(dir.join("#{name}.rb")).gsub(/#(?!\{).*/, '') }.join("\n")

      forbidden = ['raw_candidate', 'candidate_type', 'customer_language', 'cutover',
                   'conversation_id', 'message_id', 'InstallationConfig',
                   '.create', '.create!', '.save', '.update!', '.update(',
                   'HandoffService', 'ProductFlowStateStore', 'Agent::Runner',
                   'deliver', 'perform_later', 'perform_now',
                   'scan_each', 'keys_count', 'del(']
      forbidden.each { |token| expect(code).not_to include(token) }
    end
  end
end
