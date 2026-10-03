# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2c — the BOUNDED, DETERMINISTIC in-Redis acceptance-evidence retention store
# (ShadowMetricsStore precedent). Redis is a stateful in-memory fake injected via `redis:` (no live
# connection). This spec pins: a save+fetch roundtrip projecting ONLY closed fields; the bounded FIFO
# run-id index (MAX_RUNS, oldest evicted, newest first); fail-closed on an invalid run_id/kind/aggregate
# and on any Redis error; the explicit 'mutation_proof_missing' marker; the 14-day TTL (refreshed on an
# idempotent re-save); sanitization (no raw plan/text ever stored); clock injection; and the additive
# AcceptanceRunner / Parity::Runtime retention wiring. All ids are SYNTHETIC.

# A stateful in-memory Redis fake supporting exactly the ops the store uses (uniquely named so it never
# collides with another spec's helper when the whole suite loads together).
# rubocop:disable Style/OneClassPerFile -- the Redis fake and the retention spy are the two cohesive
# test doubles this one spec needs; they belong together, not in separate files.
class MarineAcceptanceEvidenceFakeRedis
  attr_reader :hashes, :lists, :ttls

  def initialize(fail: false)
    @hashes = {}
    @lists = {}
    @ttls = {}
    @fail = fail
  end

  def multi
    raise StandardError, 'redis down' if @fail

    yield self
  end

  def hset(key, fields)
    @hashes[key] = fields.transform_keys(&:to_s).transform_values(&:to_s)
  end

  def expire(key, seconds)
    @ttls[key] = seconds
  end

  def lrem(key, _count, value)
    (@lists[key] ||= []).delete(value)
  end

  def lpush(key, value)
    (@lists[key] ||= []).unshift(value)
  end

  def ltrim(key, start, stop)
    @lists[key] = ((@lists[key] ||= [])[start..stop] || [])
  end

  def hgetall(key)
    raise StandardError, 'redis down' if @fail

    (@hashes[key] || {}).dup
  end

  def lrange(key, start, stop)
    raise StandardError, 'redis down' if @fail

    (@lists[key] || [])[start..stop] || []
  end
end

# A retention spy capturing the kwargs the acceptance surfaces pass to #save (duck-typed store).
class MarineAcceptanceRetentionSpy
  attr_reader :calls

  def initialize(result: true)
    @calls = []
    @result = result
  end

  def save(**kwargs)
    @calls << kwargs
    @result
  end
end
# rubocop:enable Style/OneClassPerFile

RSpec.describe Marine::ProductAuthority::AcceptanceEvidenceStore do
  let(:fake) { MarineAcceptanceEvidenceFakeRedis.new }
  let(:clock) { -> { Time.utc(2026, 1, 1) } }

  def corpus_case(id)
    Marshal.load(Marshal.dump(Marine::ProductAuthority::Corpus.cases.find { |kase| kase[:id] == id }))
  end

  def case_result(case_id)
    outcome = { status: 'product', intents: ['price'], slot_ops: ['product'], response_goals: ['answer_price'] }
    Marine::ProductAuthority::AcceptanceCaseResult.build(
      case_id: case_id, surface: 'evaluator',
      candidate_plan_status: 'valid', exact_quantity_status: 'clear', adapter_status: 'accepted',
      planner_status: 'planned', repository_revalidation_status: 'revalidated', evidence_packet_status: 'valid',
      expected_outcome: outcome, actual_outcome: outcome, reason: 'none', passed: true
    )
  end

  def aggregate(total: 2, passed: 1, failed: 1)
    {
      schema_version: 'marine_product_authority_acceptance_run_v1', ok: true,
      total_executed: total, passed: passed, failed: failed, not_executed: 0, all_evaluated: true,
      failures: ['x'], failure_reasons: { 'outcome_mismatch' => 1 }, case_evidence: [:raw_object]
    }
  end

  def proof
    { schema_version: 'marine_product_authority_mutation_proof_v1', source: 'acceptance_runner',
      runs: 2, mutation_observed: false }
  end

  def run_key(run_id)
    "#{described_class::KEY_PREFIX}:#{run_id}"
  end

  describe '#save + #fetch roundtrip' do
    subject(:snap) { described_class.fetch(run_id: 'run_abc', redis: fake) }

    let(:rows) { [case_result('c1'), case_result('c2')] }

    before do
      described_class.save(run_id: 'run_abc', kind: 'runner', aggregate: aggregate, case_results: rows,
                           mutation_proof: proof, clock: clock, redis: fake)
    end

    it 'projects ONLY the closed meta/aggregate/proof/case fields, deep-frozen' do
      expect(snap[:schema_version]).to eq(described_class::SCHEMA_VERSION)
      expect(snap[:run_id]).to eq('run_abc')
      expect(snap[:run_kind]).to eq('runner')
      expect(snap[:created_at]).to eq(Time.utc(2026, 1, 1).to_i)
      expect(snap[:aggregate_schema_version]).to eq('marine_product_authority_acceptance_run_v1')
      expect(snap[:aggregate]).to eq(total_executed: 2, passed: 1, failed: 1, not_executed: 0, all_evaluated: true)
      expect(snap[:mutation_proof]).to eq(schema_version: 'marine_product_authority_mutation_proof_v1',
                                          source: 'acceptance_runner', runs: 2, mutation_observed: false)
      expect(snap[:case_count]).to eq(2)
      expect(snap[:cases]).to eq(rows.map { |r| r.to_h.slice(*described_class::CASE_ROW_KEYS) })
      expect(snap).to be_frozen
    end

    it 'sets the 14-day TTL and lists the run in the newest-first index' do
      expect(fake.ttls[run_key('run_abc')]).to eq(described_class::TTL_SECONDS)
      expect(described_class.fetch_index(redis: fake)).to eq(['run_abc'])
    end
  end

  describe 'bounded FIFO index' do
    it 'keeps at most MAX_RUNS ids, newest first, evicting the oldest' do
      max = described_class::MAX_RUNS
      (0..max).each do |i|
        described_class.save(run_id: "run_#{i}", kind: 'runner', aggregate: aggregate, case_results: [],
                             mutation_proof: nil, clock: clock, redis: fake)
      end
      index = described_class.fetch_index(limit: max + 10, redis: fake)

      expect(index.length).to eq(max)
      expect(index.first).to eq("run_#{max}")
      expect(index).not_to include('run_0')
    end

    it 'de-duplicates an idempotent re-save of the same run_id (overwrites deterministically)' do
      2.times do
        described_class.save(run_id: 'run_dup', kind: 'runner', aggregate: aggregate, case_results: [case_result('c1')],
                             mutation_proof: proof, clock: clock, redis: fake)
      end
      expect(described_class.fetch_index(redis: fake).count('run_dup')).to eq(1)
      expect(described_class.fetch(run_id: 'run_dup', redis: fake)[:case_count]).to eq(1)
      expect(fake.ttls[run_key('run_dup')]).to eq(described_class::TTL_SECONDS)
    end
  end

  describe 'fail-closed' do
    it 'rejects an invalid run_id / kind / aggregate without raising' do
      ['', 'a' * 65, 'bad id!', 'has/slash'].each do |bad|
        expect(described_class.save(run_id: bad, kind: 'runner', aggregate: aggregate, case_results: [], redis: fake)).to be(false)
      end
      expect(described_class.save(run_id: 'ok', kind: 'nope', aggregate: aggregate, case_results: [], redis: fake)).to be(false)
      expect(described_class.save(run_id: 'ok', kind: 'runner', aggregate: 'not-a-hash', case_results: [], redis: fake)).to be(false)
      expect(described_class.save(run_id: 'ok', kind: 'runner', aggregate: aggregate, case_results: 'nope', redis: fake)).to be(false)
    end

    it 'returns false (never raises) on a Redis write error' do
      failing = MarineAcceptanceEvidenceFakeRedis.new(fail: true)
      expect { expect(described_class.save(run_id: 'ok', kind: 'runner', aggregate: aggregate, case_results: [], redis: failing)).to be(false) }
        .not_to raise_error
    end

    it 'returns nil on a Redis read error, an invalid id, or a missing run' do
      failing = MarineAcceptanceEvidenceFakeRedis.new(fail: true)
      expect(described_class.fetch(run_id: 'ok', redis: failing)).to be_nil
      expect(described_class.fetch(run_id: '', redis: fake)).to be_nil
      expect(described_class.fetch(run_id: 'never_saved', redis: fake)).to be_nil
    end

    it 'fails the whole save closed when a case result cannot be projected (no #to_h)' do
      expect(described_class.save(run_id: 'ok', kind: 'runner', aggregate: aggregate,
                                  case_results: [Object.new], mutation_proof: nil, clock: clock, redis: fake)).to be(false)
    end
  end

  describe 'mutation-proof absence' do
    it 'stores the explicit mutation_proof_missing marker when no proof is supplied' do
      described_class.save(run_id: 'run_noproof', kind: 'parity', aggregate: aggregate, case_results: [],
                           mutation_proof: nil, clock: clock, redis: fake)
      expect(described_class.fetch(run_id: 'run_noproof', redis: fake)[:mutation_proof])
        .to eq(described_class::MUTATION_PROOF_MISSING)
    end
  end

  describe 'sanitization (no raw data)' do
    it 'drops any non-closed key from a case row (plan payloads / raw text never stored)' do
      rogue = double('rogue_result', to_h: case_result('c1').to_h.merge(
        plan: { 'secret' => 'SECRET-PLAN-VALUE' }, message: 'SECRET-MESSAGE-TEXT'
      ))
      described_class.save(run_id: 'run_clean', kind: 'runner', aggregate: aggregate, case_results: [rogue],
                           mutation_proof: nil, clock: clock, redis: fake)

      stored_cases = fake.hashes[run_key('run_clean')]['cases']
      expect(stored_cases).to include('c1')
      expect(stored_cases).not_to include('SECRET-PLAN-VALUE')
      expect(stored_cases).not_to include('SECRET-MESSAGE-TEXT')
      expect(described_class.fetch(run_id: 'run_clean', redis: fake)[:cases].first.keys)
        .to match_array(described_class::CASE_ROW_KEYS)
    end
  end

  describe 'retention wiring (additive, fail-closed)' do
    runner = Marine::ProductAuthority::AcceptanceRunner
    # Touch IntakeAdapters first so the cohesive intake_adapters.rb (which also defines the sibling
    # Runtime) is loaded before the first Runtime reference — Zeitwerk maps the file to IntakeAdapters.
    _intake = Marine::ProductAuthority::Parity::IntakeAdapters
    parity = Marine::ProductAuthority::Parity::Runtime

    it 'AcceptanceRunner.run(retention:) saves kind runner with the aggregate, case results, and a clean mutation proof' do
      spy = MarineAcceptanceRetentionSpy.new
      report = runner.run([corpus_case('price_resolved')], retention: spy)

      expect(spy.calls.length).to eq(1)
      call = spy.calls.first
      expect(call[:kind]).to eq('runner')
      expect(call[:aggregate]).to eq(report)
      expect(call[:case_results]).to eq(report[:case_evidence])
      expect(call[:mutation_proof]).to include(schema_version: 'marine_product_authority_mutation_proof_v1',
                                               source: 'acceptance_runner', mutation_observed: false)
      expect(call[:mutation_proof][:runs]).to be_positive
    end

    it 'AcceptanceRunner default (retention: nil) stores nothing and yields an identical report' do
      spy = MarineAcceptanceRetentionSpy.new
      with_retention = runner.run([corpus_case('price_resolved')], retention: spy)
      without_retention = runner.run([corpus_case('price_resolved')])

      # Identical report shape (CaseResult objects compare by identity, so project them through #to_h).
      projection = lambda do |report|
        report.merge(case_evidence: report[:case_evidence].map(&:to_h))
      end
      expect(projection.call(without_retention)).to eq(projection.call(with_retention))
    end

    it 'Parity::Runtime.run(retention:) saves kind parity with the per-surface case results' do
      spy = MarineAcceptanceRetentionSpy.new
      report = parity.run([corpus_case('price_resolved')], retention: spy)
      call = spy.calls.first

      expect(call[:kind]).to eq('parity')
      expect(call[:aggregate]).to eq(report)
      expected_rows = report[:case_evidence].flat_map { |entry| [entry[:conversation], entry[:playground]] }.compact
      expect(call[:case_results]).to eq(expected_rows)
    end

    it 'leaves the run unchanged when the store save fails' do
      failing_spy = MarineAcceptanceRetentionSpy.new(result: false)
      report = runner.run([corpus_case('price_resolved')], retention: failing_spy)

      expect(report[:ok]).to be(true)
      expect(report[:total_executed]).to eq(1)
    end
  end
end
