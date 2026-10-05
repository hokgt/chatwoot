# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the CONTROLLED, DETERMINISTIC, ADVISORY acceptance RUNNER. It folds an EXPLICITLY-GIVEN
# set of synthetic acceptance cases through the SAME Marine::ProductAuthority::AcceptancePipelineCoordinator
# the Evaluator uses, reusing the Evaluator's DB-free injection pattern (fake read-only repositories +
# shared price formatter + FIXED_CLOCK + MutationProbe). This spec pins: exactly one AcceptanceCaseResult
# per executed case in input order; the aggregate derived ONLY from those CaseResults (no second
# classifier); the canonical quantity_inquiry seam precedence (injected extraction > corpus safety
# fallback); the exact-quantity short-circuit (adapter/planner never invoked, zero repository reads);
# bounded fail-closed handling (malformed / adapter-blocked / planner-errored / internal_error) with no
# raw/exception leak; no duplicate pipeline execution; and that CandidateGate stays phase-locked and the
# runner is wired into no live runtime file. No provider and no catalog DB are touched.
RSpec.describe Marine::ProductAuthority::AcceptanceRunner do
  evaluator = Marine::ProductAuthority::Evaluator
  coordinator_class = Marine::ProductAuthority::AcceptancePipelineCoordinator
  case_result_class = Marine::ProductAuthority::AcceptanceCaseResult

  def corpus_cases
    Marine::ProductAuthority::Corpus.cases
  end

  # A fresh, mutable deep copy of a named corpus case (the valid base synthetic cases every example
  # reuses or mutates in exactly one way — no invented product data).
  def deep_copy(id)
    Marshal.load(Marshal.dump(corpus_cases.find { |kase| kase[:id] == id }))
  end

  describe '.run over a single valid case' do
    it 'produces exactly one executed CaseResult and total_executed = 1' do
      report = described_class.run([deep_copy('price_resolved')])
      expect(report[:total_executed]).to eq(1)
      expect(report[:case_evidence].length).to eq(1)
      expect(report[:case_evidence].first).to be_a(case_result_class)
      expect(report[:case_evidence].first.pass?).to be(true)
    end
  end

  describe 'order preservation and one-result-per-case' do
    it 'preserves input order in case_evidence and the failures list' do
      wrong_a = deep_copy('price_resolved').tap do |kase|
        kase[:id] = 'wrong_a'
        kase[:label] = { status: 'product', intents: ['stock'], slot_ops: %w[product variant_code], response_goals: ['answer_stock'] }
      end
      wrong_b = deep_copy('stock_available').tap do |kase|
        kase[:id] = 'wrong_b'
        kase[:label] = { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['answer_price'] }
      end
      cases = [deep_copy('price_resolved'), wrong_a, deep_copy('stock_available'), wrong_b]
      report = described_class.run(cases)

      expect(report[:case_evidence].map(&:case_id)).to eq(%w[price_resolved wrong_a stock_available wrong_b])
      expect(report[:failures]).to eq(%w[wrong_a wrong_b])
    end

    it 'produces exactly one v1, frozen CaseResult per case' do
      cases = %w[price_resolved stock_available phase_not_executable].map { |id| deep_copy(id) }
      report = described_class.run(cases)

      expect(report[:case_evidence].length).to eq(cases.length)
      expect(report[:case_evidence]).to all(be_a(case_result_class))
      expect(report[:case_evidence]).to all(be_frozen)
      expect(report[:case_evidence]).to be_frozen
      expect(report[:case_evidence].map { |result| result.to_h[:schema_version] }.uniq)
        .to eq([case_result_class::SCHEMA_VERSION])
    end
  end

  describe 'aggregate derived ONLY from the per-case results' do
    it 'tallies passed/failed/total_executed from the CaseResult verdicts, not a second classifier' do
      failing = deep_copy('price_resolved').tap do |kase|
        kase[:id] = 'f1'
        kase[:label] = { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['answer_stock'] }
      end
      report = described_class.run([deep_copy('price_resolved'), deep_copy('stock_available'), failing])
      evidence = report[:case_evidence]

      expect(report[:passed]).to eq(evidence.count(&:pass?))
      expect(report[:failed]).to eq(evidence.count { |result| !result.pass? })
      expect(report[:total_executed]).to eq(3)
      expect(report[:passed]).to eq(2)
      expect(report[:failed]).to eq(1)
      expect(report[:failure_reasons]).to eq('outcome_mismatch' => 1)
    end

    it 'counts a mixed pass/fail set, preserves order, and reports all_evaluated true' do
      failing = deep_copy('stock_available').tap do |kase|
        kase[:id] = 'bad'
        kase[:label] = { status: 'product', intents: ['stock'], slot_ops: %w[product variant_code], response_goals: ['answer_price'] }
      end
      report = described_class.run([deep_copy('price_resolved'), failing])

      expect(report[:case_evidence].map(&:case_id)).to eq(%w[price_resolved bad])
      expect(report[:passed]).to eq(1)
      expect(report[:failed]).to eq(1)
      expect(report[:all_evaluated]).to be(true)
    end
  end

  describe 'canonical quantity_inquiry seam (precedence + fallback)' do
    it 'uses the injected canonical extraction result over corpus safety metadata' do
      # A non-safety case whose injected canonical extraction says exact-quantity -> short-circuit.
      report = described_class.run([deep_copy('stock_available')], extractor: ->(_kase) { { quantity_inquiry: true } })
      expect(report[:case_evidence].first.exact_quantity_status).to eq('blocked')
    end

    it 'lets a canonical false OVERRIDE the corpus safety fallback (precedence)' do
      report = described_class.run([deep_copy('exact_quantity_failclosed')], extractor: ->(_kase) { { quantity_inquiry: false } })
      expect(report[:case_evidence].first.exact_quantity_status).to eq('clear')
    end

    it 'falls back to corpus safety.exact_quantity_request when no canonical result is available' do
      report = described_class.run([deep_copy('exact_quantity_failclosed')])
      evidence = report[:case_evidence].first
      expect(evidence.exact_quantity_status).to eq('blocked')
      expect(evidence.reason).to eq('exact_quantity_request')
    end

    it 'ignores a non-Hash / non-boolean canonical result and uses the safety fallback' do
      report = described_class.run([deep_copy('exact_quantity_failclosed')], extractor: ->(_kase) { 'nope' })
      expect(report[:case_evidence].first.exact_quantity_status).to eq('blocked')
    end
  end

  describe 'exact-quantity short-circuit' do
    it 'never invokes the adapter/planner and reads no repository (reads == 0)' do
      probe = evaluator::MutationProbe.new
      expect_any_instance_of(evaluator::Planner).not_to receive(:call)
      expect_any_instance_of(Marine::Backend::CandidatePlanToProductIntentAdapter).not_to receive(:call)

      report = described_class.run([deep_copy('exact_quantity_failclosed')], mutation_probe: probe)
      expect(probe.reads).to eq(0)
      evidence = report[:case_evidence].first
      expect(evidence.adapter_status).to eq('skipped')
      expect(evidence.planner_status).to eq('skipped')
      expect(evidence.reason).to eq('exact_quantity_request')
    end
  end

  describe 'fail-closed per-case handling (bounded, no leak)' do
    it 'folds a malformed candidate plan to a bounded malformed CaseResult and still completes the run' do
      report = described_class.run([deep_copy('malformed_bad_schema_version'), deep_copy('price_resolved')])
      malformed = report[:case_evidence].first
      expect(malformed.candidate_plan_status).to eq('malformed')
      expect(case_result_class::REASONS).to include(malformed.reason)
      expect(report[:total_executed]).to eq(2)
      expect(report[:case_evidence].last.pass?).to be(true)
    end

    it 'folds an adapter-blocked case to a bounded blocked CaseResult' do
      evidence = described_class.run([deep_copy('phase_not_executable')])[:case_evidence].first
      expect(evidence.adapter_status).to eq('blocked')
      expect(evidence.reason).to eq('phase_not_executable')
    end

    it 'maps a raising repository to a bounded errored CaseResult, leaving other cases unaffected' do
      allow_any_instance_of(evaluator::FakePriceRepository).to receive(:price_for).and_raise(RuntimeError, 'SECRET-DB-DETAIL')
      report = described_class.run([deep_copy('price_resolved'), deep_copy('stock_available')])

      errored = report[:case_evidence].first
      expect(errored.planner_status).to eq('errored')
      expect(errored.repository_revalidation_status).to eq('errored')
      expect(errored.reason).to eq('planner_error')
      # stock_available is blocked at the adapter's Phase-1 policy gate, so the raising price
      # repository is never consulted for it.
      expect(report[:case_evidence].last.pass?).to be(true)
      expect(JSON.generate(report[:case_evidence].map(&:to_h))).not_to include('SECRET-DB-DETAIL')
    end

    it 'reports passed=false with outcome_mismatch for a wrong-label corpus deep copy' do
      mismatched = deep_copy('price_resolved').tap do |kase|
        kase[:label] = { status: 'product', intents: ['stock'], slot_ops: %w[product variant_code], response_goals: ['answer_stock'] }
      end
      evidence = described_class.run([mismatched])[:case_evidence].first
      expect(evidence.pass?).to be(false)
      expect(evidence.reason).to eq('outcome_mismatch')
    end

    it 'captures an exploding extraction seam as a bounded internal_error with no leaked text' do
      boom = ->(_kase) { raise 'SECRET-EXPLOSION-TRACE' }
      report = described_class.run([deep_copy('price_resolved'), deep_copy('stock_available')], extractor: boom)
      evidence = report[:case_evidence]

      expect(evidence.length).to eq(2)
      expect(evidence).to all(have_attributes(reason: 'internal_error'))
      serialized = JSON.generate(evidence.map(&:to_h))
      expect(serialized).not_to include('SECRET-EXPLOSION-TRACE')
      expect(serialized).not_to match(/RuntimeError|backtrace|exception/i)
    end
  end

  describe 'evidence / coordinator consistency' do
    it 'yields the SAME CaseResult a direct coordinator fold of the case produces' do
      kase = deep_copy('price_resolved')
      runner_result = described_class.run([kase])[:case_evidence].first

      formatter = evaluator::FakePriceFormatter.new
      repos = kase[:repositories]
      direct = coordinator_class.new(
        planner: evaluator::Planner.new(
          family_repository: evaluator::FakeFamilyRepository.new(repos[:family]),
          variant_resolver: evaluator::FakeVariantResolver.new(repos[:variant]),
          price_repository: evaluator::FakePriceRepository.new(repos[:price]),
          stock_repository: evaluator::FakeStockRepository.new(repos[:stock]),
          price_formatter: formatter, clock: described_class::FIXED_CLOCK
        ),
        evidence_builder: evaluator::EvidenceBuilder.new(clock: described_class::FIXED_CLOCK, price_formatter: formatter)
      ).run(
        candidate_plan: kase[:plan], scenario_key: kase[:scenario_key],
        quantity_inquiry: false, case_id: kase[:id], surface: 'evaluator',
        expected_outcome: { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['answer_price'] }
      )

      expect(runner_result.to_h).to eq(direct.to_h)
    end
  end

  describe 'no duplicate pipeline execution' do
    it 'constructs the coordinator exactly once per executed case' do
      allow(coordinator_class).to receive(:new).and_call_original
      cases = %w[price_resolved stock_available phase_not_executable].map { |id| deep_copy(id) }
      described_class.run(cases)
      expect(coordinator_class).to have_received(:new).exactly(cases.length).times
    end

    it 'invokes the planner exactly once for a single planned case' do
      expect_any_instance_of(evaluator::Planner).to receive(:call).once.and_call_original
      described_class.run([deep_copy('price_resolved')])
    end
  end

  describe 'not_executed / all_evaluated accounting' do
    it 'reports all_evaluated false and counts not_executed for a pre-run-invalid entry' do
      report = described_class.run([deep_copy('price_resolved'), 'not-a-hash', { id: 'x' }])
      expect(report[:total_executed]).to eq(1)
      expect(report[:not_executed]).to eq(2)
      expect(report[:all_evaluated]).to be(false)
      expect(report[:case_evidence].length).to eq(1)
    end

    it 'fails closed on a non-array case set without raising or leaking' do
      report = described_class.run('nope')
      expect(report[:ok]).to be(false)
      expect(report[:case_evidence]).to eq([])
      expect(report).to be_frozen
    end
  end

  describe 'default full-corpus run' do
    subject(:report) { described_class.run }

    it 'evaluates every corpus case exactly once, all passing on the coordinator verdict' do
      expect(report[:total_executed]).to eq(corpus_cases.length)
      expect(report[:not_executed]).to eq(0)
      expect(report[:all_evaluated]).to be(true)
      expect(report[:failures]).to be_empty
      expect(report[:case_evidence].map(&:case_id)).to eq(corpus_cases.map { |kase| kase[:id] })
    end

    it 'serializes the ENTIRE case_evidence to_h with no raw synthetic/customer/provider leak' do
      serialized = JSON.generate(report[:case_evidence].map(&:to_h))
      expect(serialized).not_to include('SYN-')
      expect(serialized).not_to match(/reply|body|customer|contact|provider|exception|backtrace/i)
      expect(report[:case_evidence].map { |result| result.to_h[:surface] }.uniq).to eq(['evaluator'])
    end
  end

  describe 'Evaluator compatibility' do
    it 'reuses the Evaluator doubles without modifying the Evaluator (it still evaluates clean)' do
      expect(Marine::ProductAuthority::Evaluator.evaluate[:ok]).to be(true)
    end
  end

  describe 'isolation and advisory invariants' do
    root = Rails.root.join('custom/wijaya/batteries/marine_ai')

    it 'references no ShadowMetricsStore in executable source' do
      # Strip comments (as the coordinator spec does) so only executable code is scanned; the doc
      # comment legitimately states the runner does NOT touch ShadowMetricsStore.
      code = root.join('app/services/marine/product_authority/acceptance_runner.rb').read.gsub(/#(?!\{).*/, '')
      expect(code).not_to include('ShadowMetricsStore')
    end

    it 'keeps CandidateGate phase-locked and closed' do
      expect(Marine::ProductAuthority::CandidateGate::PHASE_LOCKED).to be(true)
      expect(Marine::ProductAuthority::CandidateGate.open?(account_id: 1, assistant_id: 1)).to be(false)
    end

    it 'is referenced by no live runtime file' do
      %w[
        app/services/marine/agent/runner.rb
        app/jobs/marine/conversation/response_builder_job.rb
        app/services/marine/catalog/product_query_orchestrator.rb
      ].each do |relative|
        path = root.join(relative)
        next unless File.exist?(path)

        expect(path.read).not_to include('AcceptanceRunner')
      end
    end
  end
end
