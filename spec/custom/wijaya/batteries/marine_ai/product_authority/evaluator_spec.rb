# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the DETERMINISTIC, ADVISORY corpus Evaluator. This spec exercises the REAL Fase 3A-1
# pipeline (Marine::Backend::CandidatePlanToProductIntentAdapter + Marine::Backend::ProductExecutionPlanner)
# with the Evaluator's own injected read-only repository fakes, so NO provider and NO catalog DB are
# touched. It pins: the default corpus meets the fixed acceptance policy; CLOSED schema validation
# rejects unknown keys / out-of-vocabulary / duplicate / oversized / malformed cases fail-closed (Gap
# 1); the exact-quantity safety guard short-circuits BEFORE any adapter/planner/stock execution (Gap
# 2); the surface-aware parity harness passes for faithful surfaces and FAILS for a lossy one (Gap 3);
# and mutation evidence is MEASURED, not hardcoded, failing closed on a positive delta or missing
# observer (Gap 4).
RSpec.describe Marine::ProductAuthority::Evaluator do
  def corpus_cases
    Marine::ProductAuthority::Corpus.cases
  end

  # A fresh, mutable deep copy of the genuine price case, used as the VALID base every adversarial
  # schema example mutates in exactly one way.
  def base_case
    Marshal.load(Marshal.dump(corpus_cases.find { |kase| kase[:id] == 'price_resolved' }))
  end

  describe '.evaluate over the default corpus' do
    subject(:report) { described_class.evaluate }

    it 'returns a deep-frozen advisory report that meets the fixed acceptance policy' do
      expect(report).to be_frozen
      expect(report[:ok]).to be(true)
      # If this fails, the failing case ids are the signal for the author to adjust source/corpus.
      expect(report[:meets_policy]).to(be(true), "meets_policy=false; failing case ids: #{report[:failures].inspect}")
    end

    it 'passes every critical case and every supported case' do
      counts = report[:counts]
      expect(counts[:critical_passed]).to eq(counts[:critical_total])
      expect(counts[:supported_passed]).to eq(counts[:supported_total])
    end

    it 'scores a perfect 10000 bps supported accuracy with parity and no failures' do
      expect(report[:rates_bps][:supported_accuracy]).to eq(10_000)
      expect(report[:rates_bps][:critical_accuracy]).to eq(10_000)
      expect(report[:counts][:parity_ok]).to be(true)
      expect(report[:failures]).to be_empty
    end

    it 'reports MEASURED mutation evidence and emits a validated mutation_proof artifact (Gap 4)' do
      expect(report[:mutation_observed]).to be(false)
      expect(report[:mutation_capability]).to eq('none')
      expect(report[:counts][:observer_ok]).to be(true)
      expect(report[:counts][:runs]).to eq(corpus_cases.length)
      expect(report[:mutation_proof]).to eq(
        schema_version: Marine::ProductAuthority::ShadowAcceptance::MUTATION_PROOF_SCHEMA,
        source: 'evaluator', runs: corpus_cases.length, mutation_observed: false
      )
    end
  end

  describe 'CLOSED schema validation (Gap 1, fail-closed)' do
    it 'accepts the valid base case (control)' do
      expect(described_class.evaluate([base_case])[:ok]).to be(true)
    end

    it 'rejects duplicate case ids as duplicate_ids' do
      report = described_class.evaluate([base_case, base_case])
      expect(report).to include(ok: false, reason: 'duplicate_ids')
    end

    {
      'an unknown top-level key' => ->(c) { c[:bogus] = 1 },
      'an unknown label key' => ->(c) { c[:label][:bogus] = 1 },
      'an invalid surface' => ->(c) { c[:surface] = 'mars' },
      'an oversized id string' => ->(c) { c[:id] = 'x' * 200 },
      'an oversized capability collection' => ->(c) { c[:capabilities] = { 'scenario_1' => Array.new(100, 'p') } },
      'a malformed repositories key' => ->(c) { c[:repositories] = { bogus: {} } },
      'a non-hash repository fixture' => ->(c) { c[:repositories][:family] = 'nope' },
      'a malformed safety shape' => ->(c) { c[:safety] = { exact_quantity_request: 'yes' } },
      'an unknown safety key' => ->(c) { c[:safety] = { foo: true } },
      'a non-boolean parity flag' => ->(c) { c[:parity] = 'yes' },
      'an out-of-vocabulary intent' => ->(c) { c[:label][:intents] = ['teleport'] },
      'a symbol/string intent collision' => ->(c) { c[:label][:intents] = [:price] },
      'a duplicate intent' => ->(c) { c[:label][:intents] = %w[price price] },
      'a duplicate slot op' => ->(c) { c[:label][:slot_ops] = %w[product product] },
      'an unknown response goal' => ->(c) { c[:label][:response_goals] = ['teleport'] },
      'a duplicate response goal' => ->(c) { c[:label][:response_goals] = %w[answer_price answer_price] },
      'an unknown block reason' => lambda { |c|
        c[:label] = { status: 'blocked', intents: [], slot_ops: [], response_goals: nil, block_reason: 'nope' }
      },
      'a block reason on a non-blocked label' => ->(c) { c[:label][:block_reason] = 'unsupported_intent' }
    }.each do |label, mutate|
      it "rejects #{label} as schema_invalid" do
        kase = base_case
        mutate.call(kase)
        report = described_class.evaluate([kase])
        expect(report).to include(ok: false, reason: 'schema_invalid')
        expect(report[:meets_policy]).to be(false)
      end
    end

    it 'rejects an empty corpus as invalid_corpus' do
      expect(described_class.evaluate([])).to include(ok: false, reason: 'invalid_corpus')
    end
  end

  describe 'exact-quantity safety guard (Gap 2)' do
    let(:safety_case) { corpus_cases.find { |kase| kase[:id] == 'exact_quantity_failclosed' } }

    it 'is a CRITICAL case whose plan+fixtures would otherwise resolve to a normal stock answer' do
      expect(safety_case[:critical]).to be(true)
      expect(safety_case[:safety]).to eq(exact_quantity_request: true)
      # The stock fixture is :available — a normal run WOULD answer_stock; the guard must prevent it.
      expect(safety_case[:repositories][:stock]).to eq('SYN-VAR-ALPHA-01' => :available)
      expect(safety_case[:label]).to include(status: 'blocked', block_reason: 'exact_quantity_request')
    end

    it 'passes the case WITHOUT ever constructing the adapter, planner, or touching the stock repository' do
      expect(Marine::ProductAuthority::Evaluator::Adapter).not_to receive(:new)
      expect(Marine::ProductAuthority::Evaluator::Planner).not_to receive(:new)

      report = described_class.evaluate([safety_case])
      expect(report[:ok]).to be(true)
      expect(report[:failures]).to be_empty
      expect(report[:counts][:critical_passed]).to eq(1)
    end
  end

  describe 'surface-aware parity harness (Gap 3)' do
    # A genuinely lossy Playground surface whose normalization DROPS the variant slot operation,
    # so the folded outcome diverges from the faithful Conversation surface.
    def dropping_surface
      described_class::SurfaceContext.new(
        name: 'drops_variant',
        project: ->(turn) { turn },
        normalize: lambda do |turn|
          stripped = turn[:plan].merge(
            'slot_operations' => turn[:plan]['slot_operations'].reject { |op| op['slot'] == 'variant_input' }
          )
          { plan: stripped, scenario_key: turn[:scenario_key], capabilities: turn[:capabilities] }
        end
      )
    end

    it 'fails parity (and policy) when one surface drops a safe field' do
      surfaces = [described_class::CONVERSATION_SURFACE, dropping_surface]
      report = described_class.evaluate(corpus_cases, surfaces: surfaces)
      expect(report[:counts][:parity_ok]).to be(false)
      expect(report[:meets_policy]).to be(false)
      expect(report[:failures]).to include('parity_price')
    end

    it 'fails parity when a surface normalization is malformed (missing plan)' do
      malformed = described_class::SurfaceContext.new(
        name: 'malformed', project: ->(turn) { turn },
        normalize: ->(turn) { { scenario_key: turn[:scenario_key], capabilities: turn[:capabilities] } }
      )
      report = described_class.evaluate(corpus_cases, surfaces: [described_class::CONVERSATION_SURFACE, malformed])
      expect(report[:counts][:parity_ok]).to be(false)
      expect(report[:failures]).to include('parity_price')
    end

    it 'fails parity when the surface set is empty (missing pair)' do
      report = described_class.evaluate(corpus_cases, surfaces: [])
      expect(report[:counts][:parity_ok]).to be(false)
      expect(report[:failures]).to include('parity_price')
    end
  end

  describe 'measured mutation evidence fails closed (Gap 4)' do
    # A probe that treats every observed repository read as a mutation (a positive delta).
    def rogue_probe
      Class.new(described_class::MutationProbe) { def note_read = note_mutation }.new
    end

    # A disconnected probe that never records a run, so observer evidence is missing.
    def disconnected_probe
      Class.new(described_class::MutationProbe) { def note_run = nil }.new
    end

    it 'fails policy and emits no proof on a positive mutation delta' do
      report = described_class.evaluate(corpus_cases, mutation_probe: rogue_probe)
      expect(report[:mutation_observed]).to be(true)
      expect(report[:meets_policy]).to be(false)
      expect(report[:mutation_proof]).to be_nil
    end

    it 'fails closed when the injected observer reports no runs (missing evidence)' do
      report = described_class.evaluate(corpus_cases, mutation_probe: disconnected_probe)
      expect(report[:counts][:observer_ok]).to be(false)
      expect(report[:meets_policy]).to be(false)
      expect(report[:mutation_proof]).to be_nil
    end
  end
end
