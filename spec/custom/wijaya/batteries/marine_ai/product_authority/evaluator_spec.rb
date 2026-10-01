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

    it 'passes the case while the canonical coordinator never INVOKES the adapter/planner (short-circuit)' do
      # The per-case evidence is produced by the coordinator, which SHORT-CIRCUITS on the safety seam
      # BEFORE invoking the adapter/planner — proven by the skipped stage statuses (construction is not
      # the guarantee; non-invocation is). The aggregate score path remains a clean pass.
      report = described_class.evaluate([safety_case])
      expect(report[:ok]).to be(true)
      expect(report[:failures]).to be_empty
      expect(report[:counts][:critical_passed]).to eq(1)

      evidence = report[:case_evidence].first
      expect(evidence.exact_quantity_status).to eq('blocked')
      expect(evidence.adapter_status).to eq('skipped')
      expect(evidence.planner_status).to eq('skipped')
      expect(evidence.reason).to eq('exact_quantity_request')
      expect(evidence.pass?).to be(true)
    end

    it 'passes the strict safety-seam boolean to the coordinator as quantity_inquiry' do
      # A case WITHOUT the safety seam resolves normally (adapter+planner invoked); the same plan WITH
      # the seam short-circuits. The only difference is the strict boolean the Evaluator derives from
      # safety.exact_quantity_request and forwards to the coordinator.
      without_seam = Marshal.load(Marshal.dump(safety_case)).tap do |kase|
        kase.delete(:safety)
        kase[:label] = { status: 'product', intents: ['stock'], slot_ops: %w[product variant_code], response_goals: ['answer_stock'] }
      end
      normal = described_class.evaluate([without_seam])[:case_evidence].first
      guarded = described_class.evaluate([safety_case])[:case_evidence].first

      expect(normal.adapter_status).to eq('accepted')
      expect(normal.planner_status).to eq('planned')
      expect(guarded.exact_quantity_status).to eq('blocked')
      expect(guarded.adapter_status).to eq('skipped')
    end

    it 'never INVOKES the adapter, planner, or any repository for an exact-quantity case (reads == 0)' do
      # The strongest proof: construction is allowed, invocation is not. The coordinator short-circuits
      # on the safety seam before calling the adapter/planner, so no injected repository read ever fires.
      probe = described_class::MutationProbe.new
      expect_any_instance_of(described_class::Planner).not_to receive(:call)
      expect_any_instance_of(Marine::Backend::CandidatePlanToProductIntentAdapter).not_to receive(:call)

      described_class.evaluate([safety_case], mutation_probe: probe)
      expect(probe.reads).to eq(0)
      expect(probe.runs).to eq(1)
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

  describe 'canonical per-case evidence (AcceptancePipelineCoordinator integration)' do
    subject(:report) { described_class.evaluate }

    let(:case_result_class) { Marine::ProductAuthority::AcceptanceCaseResult }

    it 'folds each non-parity case through the coordinator once and a parity case once per surface' do
      # Single-execution architecture: every non-parity case runs the coordinator exactly once. A parity
      # case is the ONE intentional multi-run — once per synthetic surface — because parity compares
      # surface folds; the report still exposes exactly one canonical result per case.
      coordinator = Marine::ProductAuthority::AcceptancePipelineCoordinator
      allow(coordinator).to receive(:new).and_call_original
      described_class.evaluate
      non_parity = corpus_cases.count { |kase| !kase[:parity] }
      parity = corpus_cases.count { |kase| kase[:parity] }
      expected = non_parity + (parity * described_class::SURFACES.length)
      expect(coordinator).to have_received(:new).exactly(expected).times
    end

    it 'exposes exactly one ordered AcceptanceCaseResult per corpus case, all on the v1 contract' do
      evidence = report[:case_evidence]
      expect(evidence.length).to eq(corpus_cases.length)
      expect(evidence.map(&:case_id)).to eq(corpus_cases.map { |kase| kase[:id] })
      expect(evidence).to all(be_a(case_result_class))
      expect(evidence.map { |result| result.to_h[:schema_version] }.uniq).to eq([case_result_class::SCHEMA_VERSION])
    end

    it 'preserves the actual (deeply-frozen) AcceptanceCaseResult objects through deep-freezing' do
      evidence = report[:case_evidence]
      expect(report[:case_evidence]).to be_frozen
      expect(evidence).to all(be_frozen)
      # Objects are preserved, not replaced by their to_h projection.
      expect(evidence).to all(respond_to(:pass?))
      expect { evidence.first.to_h }.not_to raise_error
    end

    it 'passes the canonical per-case evidence for every default-corpus case' do
      expect(report[:case_evidence].map(&:pass?).uniq).to eq([true])
    end

    it 'yields a passing result when the normalized actual outcome matches the label' do
      matching = corpus_cases.select { |kase| kase[:label][:status] == 'product' }.first(1)
      evidence = described_class.evaluate(matching)[:case_evidence].first
      expect(evidence.pass?).to be(true)
      expect(evidence.reason).to eq('none')
    end

    it 'yields passed false (bounded outcome_mismatch) when the label disagrees with the folded outcome' do
      # A schema-valid but WRONG label (stock intent/goal for a price plan) stays within the closed
      # vocabulary, so the corpus is accepted; the coordinator folds the price plan and reports a
      # bounded outcome_mismatch rather than matching.
      mismatched = base_case.tap do |kase|
        kase[:label] = { status: 'product', intents: ['stock'], slot_ops: %w[product variant_code], response_goals: ['answer_stock'] }
      end
      evidence = described_class.evaluate([mismatched])[:case_evidence].first
      expect(evidence.pass?).to be(false)
      expect(evidence.reason).to eq('outcome_mismatch')
    end

    it 'keeps a malformed-plan case bounded and leaks no raw synthetic/customer value' do
      malformed = corpus_cases.find { |kase| kase[:id] == 'malformed_bad_schema_version' }
      evidence = described_class.evaluate([malformed])[:case_evidence].first
      expect(evidence.candidate_plan_status).to eq('malformed')
      expect(case_result_class::REASONS).to include(evidence.reason)
      serialized = JSON.generate(evidence.to_h)
      expect(serialized).not_to include('SYN-')
      expect(serialized).not_to match(/reply|body|message|conversation|contact/i)
    end

    it 'fails a malformed corpus closed with an empty, frozen per-case evidence collection' do
      invalid = described_class.evaluate([])
      expect(invalid).to include(ok: false, reason: 'invalid_corpus')
      expect(invalid[:case_evidence]).to eq([])
      expect(invalid[:case_evidence]).to be_frozen
    end

    it 'leaves the aggregate policy / counts / mutation proof untouched by the added evidence' do
      expect(report[:meets_policy]).to be(true)
      expect(report[:counts][:runs]).to eq(corpus_cases.length)
      expect(report[:mutation_observed]).to be(false)
      expect(report[:mutation_proof]).not_to be_nil
    end

    it 'does not touch ShadowMetricsStore or open the phase-locked CandidateGate' do
      source = Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/evaluator.rb').read
      expect(source).not_to include('ShadowMetricsStore')
      expect(Marine::ProductAuthority::CandidateGate::PHASE_LOCKED).to be(true)
      expect(Marine::ProductAuthority::CandidateGate.open?(account_id: 1, assistant_id: 1)).to be(false)
    end
  end

  # The aggregate is now DERIVED from the single canonical AcceptanceCaseResult, so the legacy expected
  # block_reason check is preserved via a tiny bounded map rather than a second adapter/planner run.
  #
  # COVERAGE SPLIT: `malformed_candidate_plan` and the adapter-blocked reasons are corpus-reachable and
  # exercised here; `planner_error` and `evidence_invalid` require a planner/builder that raises or
  # rejects and are covered by the coordinator's own spec (acceptance_pipeline_coordinator_spec.rb). We
  # deliberately do NOT add evaluator abstractions to force those unreachable states through the corpus.
  describe 'single-execution block-reason mapping (Gap 5)' do
    blocked_ids = %w[stock_vs_order_status unsupported_mixed_intent capability_mismatch scenario_mismatch
                     malformed_unknown_field malformed_bad_schema_version exact_quantity_failclosed]

    blocked_ids.each do |id|
      it "passes blocked case #{id} by mapping the label block_reason to the CaseResult reason" do
        kase = corpus_cases.find { |c| c[:id] == id }
        report = described_class.evaluate([kase])
        evidence = report[:case_evidence].first
        mapped = described_class::BLOCK_REASON_MAP.fetch(kase[:label][:block_reason], kase[:label][:block_reason])
        expect(evidence.reason).to eq(mapped)
        expect(report[:failures]).to be_empty
      end
    end

    it 'maps the unsupported_schema label to the plan-first malformed_candidate_plan reason' do
      kase = corpus_cases.find { |c| c[:id] == 'malformed_bad_schema_version' }
      expect(kase[:label][:block_reason]).to eq('unsupported_schema')
      evidence = described_class.evaluate([kase])[:case_evidence].first
      expect(evidence.candidate_plan_status).to eq('malformed')
      expect(evidence.reason).to eq('malformed_candidate_plan')
    end

    it 'fails a blocked case whose CaseResult reason does not match the mapped expected reason' do
      # The derived aggregate is STRICTER than the coordinator's own blocked verdict: even though the
      # coordinator passes (expected == blocked outcome), a block_reason the pipeline did not produce
      # fails the aggregate — exactly the legacy block_reason check, kept without a second execution.
      kase = Marshal.load(Marshal.dump(corpus_cases.find { |c| c[:id] == 'capability_mismatch' }))
      kase[:label][:block_reason] = 'scenario_mismatch'
      report = described_class.evaluate([kase])
      expect(report[:case_evidence].first.reason).to eq('capability_mismatch')
      expect(report[:failures]).to eq([kase[:id]])
    end
  end

  describe 'response-goal emission order (Gap 10)' do
    it 'agrees on canonical planner-emission order between the label and the CaseResult (no silent sort)' do
      compatible = corpus_cases.find { |kase| kase[:id] == 'price_stock_compatible' }
      expect(compatible[:label][:response_goals]).to eq(%w[answer_price answer_stock])
      evidence = described_class.evaluate([compatible])[:case_evidence].first
      expect(evidence.pass?).to be(true)
      # The coordinator compares response_goals ORDER-SENSITIVELY, so a passing result proves the planner
      # emits them in exactly the label's order (not merely the same set); neither side is silently sorted.
      expect(evidence.actual_outcome[:response_goals]).to eq(%w[answer_price answer_stock])
    end
  end

  describe 'evidence / aggregate agreement invariant (Gap 11)' do
    def lossy_dropping_surface
      described_class::SurfaceContext.new(
        name: 'drops_variant', project: ->(turn) { turn },
        normalize: lambda do |turn|
          stripped = turn[:plan].merge(
            'slot_operations' => turn[:plan]['slot_operations'].reject { |op| op['slot'] == 'variant_input' }
          )
          { plan: stripped, scenario_key: turn[:scenario_key], capabilities: turn[:capabilities] }
        end
      )
    end

    it 'agrees between per-case evidence pass and aggregate failures on the default corpus' do
      report = described_class.evaluate
      failed_evidence_ids = report[:case_evidence].reject(&:pass?).map(&:case_id)
      expect(failed_evidence_ids).to eq(report[:failures])
      expect(report[:failures]).to be_empty
    end

    it 'exposes the chosen FAILING surface result for a lossy parity surface, matching the aggregate failure' do
      surfaces = [described_class::CONVERSATION_SURFACE, lossy_dropping_surface]
      report = described_class.evaluate(corpus_cases, surfaces: surfaces)
      canonical = report[:case_evidence].find { |result| result.case_id == 'parity_price' }
      expect(canonical.pass?).to be(false)
      expect(report[:failures]).to include('parity_price')
    end

    it 'is aggregate-only for the injected empty surface set (bounded evidence may pass while parity fails)' do
      report = described_class.evaluate(corpus_cases, surfaces: [])
      canonical = report[:case_evidence].find { |result| result.case_id == 'parity_price' }
      # Documented narrow edge: with NO surfaces, the single bounded canonical result (from the original
      # canonical input) can itself pass, but parity is aggregate-only here and fails the case.
      expect(canonical.pass?).to be(true)
      expect(report[:counts][:parity_ok]).to be(false)
      expect(report[:failures]).to include('parity_price')
    end
  end

  describe 'per-case evidence privacy (Gap 12)' do
    it 'serializes the ENTIRE default case_evidence to_h with no raw repository/customer/provider leak' do
      report = described_class.evaluate
      payloads = report[:case_evidence].map(&:to_h)
      serialized = JSON.generate(payloads)
      # No synthetic family/variant/price tokens; no raw customer/provider/message/exception markers.
      expect(serialized).not_to include('SYN-')
      expect(serialized).not_to match(/reply|body|customer|contact|provider|exception|backtrace/i)
      # The legitimate closed-schema field NAME `surface` must survive the scrub.
      expect(payloads).to all(have_key(:surface))
      expect(payloads.map { |payload| payload[:surface] }.uniq).to eq(['evaluator'])
    end
  end
end
