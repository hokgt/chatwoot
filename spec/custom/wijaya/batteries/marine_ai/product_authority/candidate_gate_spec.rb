# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the FUTURE-FACING, READ-ONLY CandidateGate. It is PHASE-LOCKED: #open? returns false
# UNCONDITIONALLY this phase, independent of any config/acceptance value, and the phase lock is the
# first statement so the future conjunctive logic is UNREACHABLE from the live authority seam. The
# conjunctive logic lives in the pure, injectable ReadinessPolicy, which these examples exercise
# DIRECTLY (Gap 5) without ever reaching #open?. #readiness surfaces that policy's advisory verdict as
# `would_open` while #open? stays hard false. Dependencies are injected (nothing touches live config
# or Redis). All ids are SYNTHETIC.
RSpec.describe Marine::ProductAuthority::CandidateGate do
  subject(:gate) { described_class.new(config: config, store: store, acceptance: acceptance) }

  let(:config) { double('config') }
  let(:store) { double('store') }
  let(:acceptance) { double('acceptance') }

  def open_all
    allow(config).to receive(:shadow_enabled_for?).and_return(true)
    allow(config).to receive(:candidate_mode_for).and_return('shadow')
    allow(store).to receive(:snapshot).and_return(:genuine_snapshot)
    allow(acceptance).to receive(:evaluate).and_return(status: 'eligible_for_review', reason: 'thresholds_met')
  end

  it 'is phase-locked (PHASE_LOCKED == true)' do
    expect(described_class::PHASE_LOCKED).to be(true)
  end

  describe '#open?' do
    it 'ALWAYS returns false even with fully open config + acceptance, never reading any dependency' do
      open_all
      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
      expect(config).not_to have_received(:shadow_enabled_for?)
      expect(store).not_to have_received(:snapshot)
      expect(acceptance).not_to have_received(:evaluate)
    end

    it 'returns false via the class-method entry point too' do
      open_all
      expect(described_class.open?(account_id: 1, assistant_id: 3, config: config, store: store, acceptance: acceptance)).to be(false)
    end

    it 'never reads the metrics snapshot (phase lock short-circuits before the policy)' do
      open_all
      expect(store).not_to receive(:snapshot)
      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
    end
  end

  describe '#readiness' do
    it 'reports phase_locked true and the policy verdict as would_open, deep-frozen' do
      open_all
      readiness = gate.readiness(account_id: 1, assistant_id: 3)
      expect(readiness).to eq(phase_locked: true, would_open: true)
      expect(readiness).to be_frozen
      # The hard authority seam stays closed regardless of the advisory verdict.
      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
    end

    it 'reports would_open false and never reads the snapshot when the config is closed' do
      allow(config).to receive(:shadow_enabled_for?).and_return(false)
      expect(store).not_to receive(:snapshot)
      expect(gate.readiness(account_id: 1, assistant_id: 3)[:would_open]).to be(false)
    end

    it 'never raises on injected dependency errors' do
      allow(config).to receive(:shadow_enabled_for?).and_raise(StandardError, 'boom')
      expect { gate.readiness(account_id: 1, assistant_id: 3) }.not_to raise_error
      expect(gate.readiness(account_id: 1, assistant_id: 3)).to eq(phase_locked: true, would_open: false)
    end
  end

  # The future-phase conjunctive logic, tested in isolation WITHOUT reaching the phase-locked #open?.
  describe described_class::ReadinessPolicy do
    subject(:policy) { described_class.new(config: config, store: store, acceptance: acceptance) }

    it 'is ready only when every conjunctive condition holds' do
      open_all
      expect(policy.ready?(account_id: 1, assistant_id: 3)).to be(true)
    end

    it 'is not ready and never reads the snapshot when the config is closed for the assistant' do
      allow(config).to receive(:shadow_enabled_for?).and_return(false)
      expect(store).not_to receive(:snapshot)
      expect(policy.ready?(account_id: 1, assistant_id: 3)).to be(false)
    end

    it 'is not ready when the candidate mode is not staged as shadow' do
      open_all
      allow(config).to receive(:candidate_mode_for).and_return('off')
      expect(policy.ready?(account_id: 1, assistant_id: 3)).to be(false)
    end

    it 'is not ready when the acceptance report is not eligible/thresholds_met' do
      open_all
      allow(acceptance).to receive(:evaluate).and_return(status: 'hold', reason: 'mutation_proof_missing')
      expect(policy.ready?(account_id: 1, assistant_id: 3)).to be(false)
    end

    it 'is not ready for a non-positive id' do
      open_all
      expect(policy.ready?(account_id: 0, assistant_id: 3)).to be(false)
      expect(policy.ready?(account_id: 1, assistant_id: -1)).to be(false)
    end

    it 'closes (never raises) when an injected dependency raises' do
      allow(config).to receive(:shadow_enabled_for?).and_raise(StandardError, 'redis down')
      expect { policy.ready?(account_id: 1, assistant_id: 3) }.not_to raise_error
      expect(policy.ready?(account_id: 1, assistant_id: 3)).to be(false)
    end
  end

  # Mutation-proof wiring (this phase's fix): the evaluator-produced mutation proof is threaded through
  # #readiness / ReadinessPolicy#ready? into the acceptance evaluation. A nil/invalid proof, or one
  # reporting an observed mutation, stays fail-closed; the gate stays phase-locked regardless of the
  # advisory verdict. The REAL ShadowAcceptance is injected so the end-to-end consumption is proven,
  # not merely the threading. All ids/counters SYNTHETIC.
  describe 'mutation-proof wiring' do
    # The validated, evaluator-produced proof artifact acceptance requires to reach eligible.
    def valid_proof
      { schema_version: Marine::ProductAuthority::ShadowAcceptance::MUTATION_PROOF_SCHEMA,
        source: 'evaluator', runs: 19, mutation_observed: false }
    end

    # A GENUINE ShadowMetricsStore ok-snapshot honouring every conservation law with thresholds met.
    def genuine_snapshot
      { schema_version: Marine::ProductAuthority::ShadowMetricsStore::SCHEMA_VERSION, ok: true,
        account_id: 1, assistant_id: 3, days: 14,
        counters: { 'total' => 100, 'legacy_status.product' => 100, 'candidate_status.product' => 100,
                    'comparable' => 100, 'exact_agreement' => 100, 'matrix.product.product' => 100 } }
    end

    def staged_config
      double('config').tap do |config|
        allow(config).to receive(:shadow_enabled_for?).and_return(true)
        allow(config).to receive(:candidate_mode_for).and_return('shadow')
      end
    end

    def real_acceptance
      Marine::ProductAuthority::ShadowAcceptance.new
    end

    def store_returning(snapshot)
      double('store').tap { |store| allow(store).to receive(:snapshot).and_return(snapshot) }
    end

    it 'threads the evaluator mutation proof into the acceptance evaluation' do
      snapshot = genuine_snapshot
      proof = valid_proof
      acceptance = double('acceptance')
      allow(acceptance).to receive(:evaluate).and_return(status: 'eligible_for_review', reason: 'thresholds_met')
      policy = described_class::ReadinessPolicy.new(config: staged_config, store: store_returning(snapshot), acceptance: acceptance)
      expect(policy.ready?(account_id: 1, assistant_id: 3, mutation_proof: proof)).to be(true)
      expect(acceptance).to have_received(:evaluate).with(snapshot, mutation_proof: proof)
    end

    it 'with a REAL ShadowAcceptance a valid proof reaches eligible and would_open is true end-to-end' do
      policy = described_class::ReadinessPolicy.new(config: staged_config, store: store_returning(genuine_snapshot), acceptance: real_acceptance)
      expect(policy.ready?(account_id: 1, assistant_id: 3, mutation_proof: valid_proof)).to be(true)
    end

    it 'with a REAL ShadowAcceptance a missing (nil) proof is fail-closed, real report reason mutation_proof_missing' do
      acceptance = real_acceptance
      policy = described_class::ReadinessPolicy.new(config: staged_config, store: store_returning(genuine_snapshot), acceptance: acceptance)
      expect(policy.ready?(account_id: 1, assistant_id: 3, mutation_proof: nil)).to be(false)
      expect(acceptance.evaluate(genuine_snapshot, mutation_proof: nil)[:reason]).to eq('mutation_proof_missing')
    end

    it 'gate.readiness with a missing proof reports would_open false, phase_locked true' do
      gate = described_class.new(config: staged_config, store: store_returning(genuine_snapshot), acceptance: real_acceptance)
      expect(gate.readiness(account_id: 1, assistant_id: 3)).to eq(phase_locked: true, would_open: false)
      expect(gate.readiness(account_id: 1, assistant_id: 3, mutation_proof: nil)[:would_open]).to be(false)
    end

    it 'is fail-closed for every invalid or mutation-claiming proof (REAL acceptance)' do
      policy = described_class::ReadinessPolicy.new(config: staged_config, store: store_returning(genuine_snapshot), acceptance: real_acceptance)
      [
        valid_proof.merge(schema_version: 'nope'),
        valid_proof.merge(source: 'forged'),
        valid_proof.merge(runs: 0),
        valid_proof.merge(runs: 'x'),
        valid_proof.except(:runs),
        valid_proof.merge(extra: 'x'),
        valid_proof.merge(mutation_observed: true)
      ].each do |bad|
        expect(policy.ready?(account_id: 1, assistant_id: 3, mutation_proof: bad)).to be(false)
      end
    end

    it 'a proof claiming an observed mutation is fail-closed, real report reason mutation_detected' do
      report = real_acceptance.evaluate(genuine_snapshot, mutation_proof: valid_proof.merge(mutation_observed: true))
      expect(report[:reason]).to eq('mutation_detected')
    end

    it 'stays phase-locked (open? false) even when the advisory would_open verdict is true' do
      gate = described_class.new(config: staged_config, store: store_returning(genuine_snapshot), acceptance: real_acceptance)
      readiness = gate.readiness(account_id: 1, assistant_id: 3, mutation_proof: valid_proof)
      expect(readiness).to eq(phase_locked: true, would_open: true)
      expect(readiness).to be_frozen
      expect(described_class::PHASE_LOCKED).to be(true)
      expect(gate.open?(account_id: 1, assistant_id: 3)).to be(false)
    end

    it 'never reads the snapshot or evaluates when the config is closed, even with a valid proof' do
      config = double('config')
      allow(config).to receive(:shadow_enabled_for?).and_return(false)
      store = double('store')
      acceptance = double('acceptance')
      policy = described_class::ReadinessPolicy.new(config: config, store: store, acceptance: acceptance)
      expect(store).not_to receive(:snapshot)
      expect(acceptance).not_to receive(:evaluate)
      expect(policy.ready?(account_id: 1, assistant_id: 3, mutation_proof: valid_proof)).to be(false)
    end
  end
end
