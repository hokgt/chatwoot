# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the PRIVACY-SAFE Redis product-authority ShadowMetricsStore (aggregate counters only).
# Redis is fully stubbed (no live connection) and these examples pin: #record writes the exact UTC
# daily key, the exact bounded closed-vocabulary counters, and the 14-day TTL in ONE MULTI; a Redis
# failure returns false without raising; #snapshot reads ONLY the explicit <=14 daily keys (never a
# scan), merges non-negative integer counters, fails closed on a malformed field/value, and returns a
# deep-frozen ok-snapshot that carries NO self-declared mutation field. All ids/keys are SYNTHETIC.

# A minimal fake MULTI transaction capturing the hincrby/expire calls (uniquely named so it never
# collides with another spec's helper when the whole suite loads together).
class MarineProductAuthShadowFakeMulti
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

RSpec.describe Marine::ProductAuthority::ShadowMetricsStore do
  let(:transaction) { MarineProductAuthShadowFakeMulti.new }
  let(:conn) { double('conn') }

  def stub_multi
    allow(Redis::Alfred).to receive(:with).and_yield(conn)
    allow(conn).to receive(:multi).and_yield(transaction)
  end

  # rubocop:disable Metrics/ParameterLists
  def observation(legacy_status: 'product', candidate_status: 'product',
                  legacy_intents: %w[price], candidate_intents: %w[price],
                  legacy_slot_ops: %w[product], candidate_slot_ops: %w[product],
                  legacy_qty: false, candidate_qty: false, comparable: true,
                  exact: true, intents_ok: true, slots_ok: true, status_ok: true)
    instance_double(Marine::ProductAuthority::ShadowObservation,
                    account_id: 1, assistant_id: 3,
                    legacy_status: legacy_status, candidate_status: candidate_status,
                    legacy_intents: legacy_intents, candidate_intents: candidate_intents,
                    legacy_slot_ops: legacy_slot_ops, candidate_slot_ops: candidate_slot_ops,
                    legacy_quantity_inquiry?: legacy_qty, candidate_quantity_inquiry?: candidate_qty,
                    comparable?: comparable, exact_match?: exact,
                    intents_match?: intents_ok, slots_match?: slots_ok, status_match?: status_ok)
  end
  # rubocop:enable Metrics/ParameterLists

  def fields_for(obs, now: Time.utc(2026, 9, 30, 23, 30))
    stub_multi
    described_class.new.record(obs, now: now)
    transaction.incrs.map { |_key, field, _incr| field }
  end

  describe '#record' do
    it 'writes the exact daily key, bounded counters, and 14-day TTL in one MULTI for a matching comparable turn' do
      stub_multi
      expect(described_class.new.record(observation, now: Time.utc(2026, 9, 30, 23, 30))).to be(true)

      key = 'marine:product_authority:shadow:metrics:v1:1:3:20260930'
      expect(transaction.incrs.map(&:first).uniq).to eq([key])
      expect(transaction.incrs.map(&:last).uniq).to eq([1])
      fields = transaction.incrs.map { |_, field, _incr| field }
      expect(fields).to contain_exactly(
        'total', 'legacy_status.product', 'candidate_status.product',
        'legacy_intent.price', 'candidate_intent.price',
        'legacy_slot.product', 'candidate_slot.product',
        'comparable', 'matrix.product.product',
        'exact_agreement', 'intent_agreement', 'slot_agreement', 'status_agreement'
      )
      expect(transaction.expiries).to eq([[key, described_class::TTL_SECONDS]])
    end

    it 'records the quantity_inquiry counters only for the sides that set the flag' do
      fields = fields_for(observation(legacy_qty: true, candidate_qty: false))
      expect(fields).to include('quantity_inquiry.legacy')
      expect(fields).not_to include('quantity_inquiry.candidate')
    end

    it 'records no comparable / matrix / agreement counters for a non-comparable turn' do
      fields = fields_for(observation(comparable: false))
      expect(fields).to include('total', 'legacy_status.product', 'candidate_status.product')
      expect(fields).not_to include('comparable', 'matrix.product.product',
                                    'exact_agreement', 'intent_agreement', 'slot_agreement', 'status_agreement')
    end

    it 'records only the agreement counters whose flags are set' do
      fields = fields_for(observation(exact: false, intents_ok: true, slots_ok: false, status_ok: true))
      expect(fields).to include('comparable', 'intent_agreement', 'status_agreement')
      expect(fields).not_to include('exact_agreement', 'slot_agreement')
    end

    it 'returns false (never raises) when Redis fails' do
      allow(Redis::Alfred).to receive(:with).and_raise(StandardError, 'redis down')
      expect { expect(described_class.new.record(observation)).to be(false) }.not_to raise_error
    end

    it 'returns false without touching Redis when a field component is out of contract' do
      bad = observation(legacy_status: 'not_a_status')
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

    it 'reads exactly the explicit last-N daily keys (no scan), merges counters, and deep-freezes an ok-snapshot' do
      stub_pipeline([{ 'total' => '2', 'comparable' => '2' }, { 'total' => '3', 'legacy_status.product' => '1' }, {}])
      snap = described_class.new.snapshot(account_id: 1, assistant_id: 3, days: 3, now: Time.utc(2026, 9, 30, 12))

      expect(@hgetall_keys).to eq(%w[
                                    marine:product_authority:shadow:metrics:v1:1:3:20260930
                                    marine:product_authority:shadow:metrics:v1:1:3:20260929
                                    marine:product_authority:shadow:metrics:v1:1:3:20260928
                                  ])
      expect(snap.keys).to contain_exactly(:schema_version, :ok, :account_id, :assistant_id, :days, :counters)
      expect(snap[:ok]).to be(true)
      expect(snap[:counters]).to eq('total' => 5, 'comparable' => 2, 'legacy_status.product' => 1)
      expect(snap).to be_frozen
      expect(snap[:counters]).to be_frozen
    end

    it 'caps the window at 14 keys' do
      stub_pipeline([])
      described_class.new.snapshot(account_id: 1, assistant_id: 3, days: 14, now: Time.utc(2026, 9, 30, 12))
      expect(@hgetall_keys.length).to eq(14)
    end

    it 'rejects an invalid id / days as invalid_input without reading Redis' do
      expect(Redis::Alfred).not_to receive(:with)
      [{ account_id: 0 }, { assistant_id: -1 }, { days: 0 }, { days: 15 }].each do |bad|
        args = { account_id: 1, assistant_id: 3, days: 1, now: Time.utc(2026, 9, 30, 12) }.merge(bad)
        expect(described_class.new.snapshot(**args)).to include(ok: false, reason: 'invalid_input')
      end
    end

    it 'fails closed to invalid_counters on an unknown field' do
      stub_pipeline([{ 'total' => '2', 'evil.field' => '1' }])
      snap = described_class.new.snapshot(account_id: 1, assistant_id: 3, days: 1, now: Time.utc(2026, 9, 30, 12))
      expect(snap).to include(ok: false, reason: 'invalid_counters', counters: {})
      expect(snap).to be_frozen
    end

    it 'fails closed to invalid_counters on a non-integer / negative value' do
      ['1.5', '-3', 'nope', ''].each do |bad|
        stub_pipeline([{ 'total' => bad }])
        snap = described_class.new.snapshot(account_id: 1, assistant_id: 3, days: 1, now: Time.utc(2026, 9, 30, 12))
        expect(snap).to include(ok: false, reason: 'invalid_counters')
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
    it 'reads no InstallationConfig and issues no broad SCAN/KEYS/delete Redis call' do
      source = File.read(
        Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/shadow_metrics_store.rb')
      ).gsub(/#(?!\{).*/, '')

      ['InstallationConfig', 'scan_each', 'keys_count', '.scan(', 'del('].each do |token|
        expect(source).not_to include(token)
      end
    end
  end
end
