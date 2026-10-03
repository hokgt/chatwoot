# frozen_string_literal: true

require 'rails_helper'

# Langkah 3 observability — the PRIVACY-SAFE Redis Model2ShadowMetricsStore. Redis is fully stubbed
# (no live connection) and these examples pin: #record writes the exact DATE-ONLY daily key (no
# account/assistant/conversation/message id), `total` + the single `<status>.<reason>` counter, and
# the 14-day TTL in ONE MULTI; a Redis failure returns false without raising; and #snapshot reads
# ONLY the explicit <=14 daily keys (never a scan), merges non-negative integer counters, fails
# closed on any out-of-allowlist field or non-integer value, and returns a deep-frozen snapshot.
class MarineModel2ShadowFakeMulti
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

RSpec.describe Marine::Backend::Model2ShadowMetricsStore do
  exec = Marine::Backend::Model2ShadowExecution

  let(:transaction) { MarineModel2ShadowFakeMulti.new }
  let(:conn) { double('conn') }

  def observation(status, reason)
    result = Marine::Backend::Model2ShadowExecution::Result.new(status: status, reason: reason).freeze
    Marine::Backend::Model2ShadowObservation.build(result: result)
  end

  def stub_multi
    allow(Redis::Alfred).to receive(:with).and_yield(conn)
    allow(conn).to receive(:multi).and_yield(transaction)
  end

  def fields_for(obs, now: Time.utc(2026, 10, 3, 23, 30))
    stub_multi
    expect(described_class.new.record(obs, now: now)).to be(true)
    transaction.incrs
  end

  describe '#record — one increment per real required pair' do
    {
      'accepted + deliverable_wording' => [[exec::STATUS_ACCEPTED, exec::REASON_DELIVERABLE_WORDING], 'accepted.deliverable_wording'],
      'rejected + fact_rejected' => [[exec::STATUS_REJECTED, :fact_rejected], 'rejected.fact_rejected'],
      'rejected + fact_unverified' => [[exec::STATUS_REJECTED, :fact_unverified], 'rejected.fact_unverified'],
      'rejected + generation_failed' => [[exec::STATUS_REJECTED, :generation_failed], 'rejected.generation_failed'],
      'skipped + not_exact_price' => [[exec::STATUS_SKIPPED, exec::REASON_NOT_EXACT_PRICE], 'skipped.not_exact_price'],
      'skipped + invalid_packet' => [[exec::STATUS_SKIPPED, exec::REASON_INVALID_PACKET], 'skipped.invalid_packet']
    }.each do |label, ((status, reason), field)|
      it "increments total + #{field} for #{label} under a date-only key" do
        incrs = fields_for(observation(status, reason))

        key = 'marine:model2:shadow:metrics:v1:20261003'
        expect(incrs.map(&:first).uniq).to eq([key])
        expect(incrs.map(&:last).uniq).to eq([1])
        expect(incrs.map { |_, f, _| f }).to contain_exactly('total', field)
        expect(transaction.expiries).to eq([[key, described_class::TTL_SECONDS]])
      end
    end
  end

  describe '#record — privacy / fail-closed' do
    it 'the daily key carries NO account/assistant/conversation/message id — only the date' do
      incrs = fields_for(observation(exec::STATUS_ACCEPTED, exec::REASON_DELIVERABLE_WORDING))
      expect(incrs.map(&:first).uniq).to eq(['marine:model2:shadow:metrics:v1:20261003'])
    end

    it 'the whole static field allowlist is exactly total + the enumerated status/reason pairs' do
      expect(described_class::STATIC_FIELDS.first).to eq('total')
      expect(described_class::PAIR_FIELDS).to all(match(/\A(accepted|rejected|skipped)\.[a-z_]+\z/))
      # No field can carry a price, code, language, or id fragment.
      expect(described_class::STATIC_FIELDS.join(' ')).not_to match(/\d|Rp|IDR|BD-|conversation|message|account|assistant|contact/)
    end

    it 'returns false without writing for an out-of-contract observation (never a broad object)' do
      bad = double('obs', status: :accepted, reason: :teleported)
      expect(Redis::Alfred).not_to receive(:with)
      expect(described_class.new.record(bad)).to be(false)
    end

    it 'returns false without writing for an impossible status/reason pair' do
      bad = double('obs', status: :skipped, reason: :deliverable_wording)
      expect(Redis::Alfred).not_to receive(:with)
      expect(described_class.new.record(bad)).to be(false)
    end

    it 'returns false (never raises) when Redis fails' do
      allow(Redis::Alfred).to receive(:with).and_raise(StandardError, 'redis down')
      obs = observation(exec::STATUS_ACCEPTED, exec::REASON_DELIVERABLE_WORDING)
      expect { expect(described_class.new.record(obs)).to be(false) }.not_to raise_error
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

    it 'reads exactly the explicit last-N date-only keys (no scan) and merges integer counters' do
      stub_pipeline([{ 'total' => '2', 'accepted.deliverable_wording' => '2' },
                     { 'total' => '3', 'skipped.not_exact_price' => '1' }, {}])
      expect(Redis::Alfred).not_to receive(:scan_each)

      snap = described_class.new.snapshot(days: 3, now: Time.utc(2026, 10, 3, 12))
      expect(@hgetall_keys).to eq(%w[
                                    marine:model2:shadow:metrics:v1:20261003
                                    marine:model2:shadow:metrics:v1:20261002
                                    marine:model2:shadow:metrics:v1:20261001
                                  ])
      expect(snap[:ok]).to be(true)
      expect(snap[:counters]).to eq('total' => 5, 'accepted.deliverable_wording' => 2, 'skipped.not_exact_price' => 1)
      expect(snap).to be_frozen
      expect(snap[:counters]).to be_frozen
    end

    it 'caps the window at 14 keys' do
      stub_pipeline([])
      described_class.new.snapshot(days: 14, now: Time.utc(2026, 10, 3, 12))
      expect(@hgetall_keys.length).to eq(14)
    end

    it 'fails closed to an error snapshot on a field outside the static allowlist' do
      stub_pipeline([{ 'total' => '2', 'accepted.Rp12500' => '1' }])
      snap = described_class.new.snapshot(days: 1, now: Time.utc(2026, 10, 3, 12))
      expect(snap).to include(ok: false, reason: 'invalid_counters', counters: {})
      expect(snap).to be_frozen
    end

    it 'fails closed on a non-integer / negative value' do
      ['1.5', '-3', 'nope', ''].each do |bad|
        stub_pipeline([{ 'total' => bad }])
        snap = described_class.new.snapshot(days: 1, now: Time.utc(2026, 10, 3, 12))
        expect(snap[:ok]).to be(false)
      end
    end

    it 'rejects an invalid days / time as invalid_input without reading Redis' do
      expect(Redis::Alfred).not_to receive(:with)
      now = Time.utc(2026, 10, 3, 12)
      [{ days: 0, now: now }, { days: 15, now: now }, { days: 1, now: 'nope' }].each do |args|
        snap = described_class.new.snapshot(**args)
        expect(snap).to include(ok: false, reason: 'invalid_input')
      end
    end

    it 'returns a safe read_error snapshot when Redis raises' do
      allow(Redis::Alfred).to receive(:with).and_raise(StandardError, 'redis down')
      snap = described_class.new.snapshot(days: 1, now: Time.utc(2026, 10, 3, 12))
      expect(snap).to include(ok: false, reason: 'read_error', counters: {})
      expect(snap).to be_frozen
    end
  end

  describe 'privacy / no side effects (source proof)' do
    it 'persists no identifier / customer text / reply / state write and uses no scan' do
      dir = Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/backend')
      code = %w[model2_shadow_observation model2_shadow_metrics_store]
             .map { |name| File.read(dir.join("#{name}.rb")).gsub(/#(?!\{).*/, '') }.join("\n")

      forbidden = ['account_id', 'assistant_id', 'conversation_id', 'message_id', 'contact',
                   'InstallationConfig', '.create', '.create!', '.save', '.update!', '.update(',
                   'HandoffService', 'ProductFlowStateStore', 'Agent::Runner',
                   'deliver', 'perform_later', 'perform_now', 'scan_each', 'keys_count', 'del(']
      forbidden.each { |token| expect(code).not_to include(token) }
    end
  end
end
