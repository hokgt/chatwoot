# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the acceptance-only pipeline coordinator. It folds ONE synthetic candidate plan through
# the REAL Fase 3A-1 backend pipeline (adapter -> planner -> evidence packet builder) with INJECTED
# read-only repository fakes, and projects the result into a bounded, closed-schema AcceptanceCaseResult.
# These specs prove the end-to-end happy path, the exact-quantity short-circuit, fail-closed handling,
# the absence of reply/raw-data/side-effects, the default read-only repository wiring, and that
# Candidate authority / ShadowMetricsStore / live runtime stay untouched. No catalog DB is touched.
RSpec.describe Marine::ProductAuthority::AcceptancePipelineCoordinator, type: :model do
  evaluator = Marine::ProductAuthority::Evaluator

  let(:clock) { -> { Time.utc(2026, 1, 1) } }
  let(:price_formatter) { evaluator::FakePriceFormatter.new }

  let(:family_repository) { evaluator::FakeFamilyRepository.new('SYN-FAM-ALPHA' => { code: 'SYN-FAM-ALPHA', name: 'Synthetic Alpha' }) }
  let(:variant_resolver) { evaluator::FakeVariantResolver.new('SYN-VAR-ALPHA-01' => { status: :resolved, code: 'SYN-VAR-ALPHA-01' }) }
  let(:price_fixture) { { status: :available, price_list_rate: 125_000, currency: 'IDR', uom: 'pcs' } }
  let(:price_repository) { evaluator::FakePriceRepository.new('SYN-VAR-ALPHA-01' => price_fixture) }
  let(:stock_repository) { evaluator::FakeStockRepository.new('SYN-VAR-ALPHA-01' => :available) }

  let(:planner) do
    Marine::Backend::ProductExecutionPlanner.new(
      family_repository: family_repository, variant_resolver: variant_resolver,
      price_repository: price_repository, stock_repository: stock_repository,
      price_formatter: price_formatter, clock: clock
    )
  end
  # The evidence builder shares the SAME deterministic price formatter so a price fact's reconstructed
  # display matches the planner's — a DB-free deterministic end-to-end run.
  let(:evidence_builder) { Marine::Backend::EvidencePacketBuilder.new(clock: clock, price_formatter: price_formatter) }

  let(:coordinator) { described_class.new(planner: planner, evidence_builder: evidence_builder) }

  def plan_for(intents, variant_code: 'SYN-VAR-ALPHA-01', variant_type: 'variant_code', family_code: 'SYN-FAM-ALPHA')
    {
      'schema_version' => 'marine_decision_v1',
      'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
      'intents' => intents,
      'slot_operations' => [
        { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => family_code, 'candidate_type' => 'family_code' } },
        { 'operation' => 'set', 'slot' => 'variant_input', 'value' => { 'raw_candidate' => variant_code, 'candidate_type' => variant_type } }
      ],
      'customer_language' => 'en', 'confidence' => 'high'
    }
  end

  def run(plan:, expected:, quantity_inquiry: false, case_id: 'syn_case_01', surface: 'evaluator')
    coordinator.run(candidate_plan: plan, scenario_key: 'scenario_1',
                    quantity_inquiry: quantity_inquiry, case_id: case_id, surface: surface, expected_outcome: expected)
  end

  describe 'successful end-to-end flow' do
    it 'runs adapter -> planner -> evidence builder and passes on a matching price case' do
      expected = { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['answer_price'] }
      result = run(plan: plan_for(['price']), expected: expected)

      expect(result).to be_frozen
      expect(result.pass?).to be(true)
      expect(result.reason).to eq('none')
      expect(result.candidate_plan_status).to eq('valid')
      expect(result.exact_quantity_status).to eq('clear')
      expect(result.adapter_status).to eq('accepted')
      expect(result.planner_status).to eq('planned')
      expect(result.repository_revalidation_status).to eq('revalidated')
      expect(result.evidence_packet_status).to eq('valid')
      expect(result.actual_outcome).to eq(expected)
    end

    it 'blocks a supported-but-not-executable stock case at the adapter policy gate, before the planner' do
      # Phase 1 (Opsi B): stock is a supported product intent but NOT executable — the adapter
      # fails the whole plan closed with the bounded policy reason, the planner/evidence builder
      # are skipped, and no repository is read.
      expected = { status: 'blocked', intents: [], slot_ops: [], response_goals: [] }
      result = run(plan: plan_for(['stock']), expected: expected)
      expect(result.adapter_status).to eq('blocked')
      expect(result.planner_status).to eq('skipped')
      expect(result.evidence_packet_status).to eq('skipped')
      expect(result.reason).to eq('phase_not_executable')
      expect(result.pass?).to be(true)
      expect(result.actual_outcome[:status]).to eq('blocked')
    end

    it 'records a bounded outcome_mismatch (not a crash) when actual diverges from expected' do
      wrong = { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['handoff'] }
      result = run(plan: plan_for(['price']), expected: wrong)
      expect(result.pass?).to be(false)
      expect(result.reason).to eq('outcome_mismatch')
      expect(result.planner_status).to eq('planned')
    end
  end

  describe 'exact-quantity precheck' do
    it 'fails closed to a blocked result BEFORE the adapter and planner are ever called' do
      spy_adapter = instance_double(Marine::Backend::CandidatePlanToProductIntentAdapter)
      spy_planner = instance_double(Marine::Backend::ProductExecutionPlanner)
      expect(spy_adapter).not_to receive(:call)
      expect(spy_planner).not_to receive(:call)
      coordinator = described_class.new(adapter: spy_adapter, planner: spy_planner, evidence_builder: evidence_builder)

      expected = { status: 'blocked', intents: [], slot_ops: [], response_goals: [] }
      result = coordinator.run(candidate_plan: plan_for(['stock']), scenario_key: 'scenario_1',
                               quantity_inquiry: true,
                               case_id: 'syn_qty_01', surface: 'evaluator', expected_outcome: expected)

      expect(result.exact_quantity_status).to eq('blocked')
      expect(result.adapter_status).to eq('skipped')
      expect(result.planner_status).to eq('skipped')
      expect(result.reason).to eq('exact_quantity_request')
      expect(result.pass?).to be(true)
      expect(result.actual_outcome[:status]).to eq('blocked')
    end
  end

  describe 'adapter fail-closed' do
    it 'reports a bounded adapter block reason and skips planner/evidence' do
      expected = { status: 'blocked', intents: [], slot_ops: [], response_goals: [] }
      # Phase 1: a supported but non-executable intent set fails the backend-owned policy gate
      # (scenario configuration no longer participates in authorization).
      result = coordinator.run(candidate_plan: plan_for(['stock']), scenario_key: 'scenario_1',
                               quantity_inquiry: false,
                               case_id: 'syn_cap_01', surface: 'evaluator', expected_outcome: expected)
      expect(result.adapter_status).to eq('blocked')
      expect(result.planner_status).to eq('skipped')
      expect(result.reason).to eq('phase_not_executable')
      expect(result.pass?).to be(true)
    end

    it 'degrades an unknown/secret adapter block reason to internal_error and FAILS without leaking it' do
      secret_reason = 'SECRET-UNLISTED-REASON'
      rogue = instance_double(Marine::Backend::CandidatePlanToProductIntentAdapter)
      allow(rogue).to receive(:call).and_return(
        Marine::Backend::CandidatePlanToProductIntentAdapter::Result.new(
          ok: false, reason: secret_reason, scenario: nil, intents: nil, operations: nil, product_intent: nil
        )
      )
      coordinator = described_class.new(adapter: rogue, planner: planner, evidence_builder: evidence_builder)
      # Even though the case EXPECTS a blocked outcome, an out-of-allowlist reason can never be attested
      # as a correct block.
      expected = { status: 'blocked', intents: [], slot_ops: [], response_goals: [] }
      result = coordinator.run(candidate_plan: plan_for(['price']), scenario_key: 'scenario_1',
                               quantity_inquiry: false,
                               case_id: 'syn_rogue_01', surface: 'evaluator', expected_outcome: expected)

      expect(result.adapter_status).to eq('blocked')
      expect(result.reason).to eq('internal_error')
      expect(result.pass?).to be(false)
      expect(result.to_h.to_s).not_to include(secret_reason)
    end
  end

  describe 'repository revalidation attestation does not overclaim' do
    it 'attests not_revalidated for a planner clarification that validated no slot or fact' do
      # An unknown family resolves to nil -> the planner COMPLETES with a clarify_product goal and an
      # empty validated_slots/facts block, so the attestation must not claim `revalidated`.
      expected = { status: 'product', intents: ['price'], slot_ops: %w[product variant_code],
                   response_goals: ['clarify_product'] }
      result = run(plan: plan_for(['price'], family_code: 'SYN-FAM-UNKNOWN'), expected: expected)

      expect(result.planner_status).to eq('planned')
      expect(result.repository_revalidation_status).to eq('not_revalidated')
      expect(result.pass?).to be(true)
    end
  end

  describe 'malformed input and exceptions fail closed without leaking text' do
    it 'flags a malformed candidate plan' do
      expected = { status: 'blocked', intents: [], slot_ops: [], response_goals: [] }
      result = run(plan: { 'schema_version' => 'not_real', 'intents' => ['price'] }, expected: expected)
      expect(result.candidate_plan_status).to eq('malformed')
      expect(result.reason).to eq('malformed_candidate_plan')
    end

    it 'flags a malformed expected outcome' do
      result = run(plan: plan_for(['price']), expected: { status: 'invented' })
      expect(result.reason).to eq('malformed_input')
      expect(result.candidate_plan_status).to eq('skipped')
      expect(result.pass?).to be(false)
    end

    it 'maps a planner error to a bounded planner_error reason with no exception text' do
      exploding = instance_double(Marine::Backend::ProductExecutionPlanner)
      allow(exploding).to receive(:call).and_raise(RuntimeError, 'SECRET-DB-DETAIL')
      coordinator = described_class.new(planner: exploding, evidence_builder: evidence_builder)
      expected = { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['answer_price'] }

      result = coordinator.run(candidate_plan: plan_for(['price']), scenario_key: 'scenario_1',
                               quantity_inquiry: false,
                               case_id: 'syn_err_01', surface: 'evaluator', expected_outcome: expected)
      expect(result.planner_status).to eq('errored')
      expect(result.repository_revalidation_status).to eq('errored')
      expect(result.reason).to eq('planner_error')
      expect(result.pass?).to be(false)
      expect(result.to_h.to_s).not_to include('SECRET-DB-DETAIL')
    end

    it 'maps an unexpected adapter exception to a generic internal_error with no leaked text' do
      exploding = instance_double(Marine::Backend::CandidatePlanToProductIntentAdapter)
      allow(exploding).to receive(:call).and_raise(RuntimeError, 'SECRET-TRACE')
      coordinator = described_class.new(adapter: exploding, planner: planner, evidence_builder: evidence_builder)
      expected = { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['answer_price'] }

      result = coordinator.run(candidate_plan: plan_for(['price']), scenario_key: 'scenario_1',
                               quantity_inquiry: false,
                               case_id: 'syn_int_01', surface: 'evaluator', expected_outcome: expected)
      expect(result.reason).to eq('internal_error')
      expect(result.pass?).to be(false)
      expect(result.to_h.to_s).not_to include('SECRET-TRACE')
    end
  end

  describe 'bounded, privacy-safe artifact (no reply/delivery/raw data)' do
    it 'carries only closed-schema keys and never a raw candidate value or reply text' do
      expected = { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['answer_price'] }
      serialized = JSON.generate(run(plan: plan_for(['price']), expected: expected).to_h)

      expect(serialized).not_to include('SYN-FAM-ALPHA')
      expect(serialized).not_to include('SYN-VAR-ALPHA-01')
      expect(serialized).not_to match(/reply|text|body|message|conversation|contact/i)
    end
  end

  describe 'default dependency wiring (read-only repositories, no DB access)' do
    it 'defaults to the existing adapter/planner/builder and the real read-only repository classes' do
      default = described_class.new
      default_planner = default.instance_variable_get(:@planner)
      expect(default.instance_variable_get(:@adapter)).to be_a(Marine::Backend::CandidatePlanToProductIntentAdapter)
      expect(default_planner).to be_a(Marine::Backend::ProductExecutionPlanner)
      expect(default.instance_variable_get(:@evidence_builder)).to be_a(Marine::Backend::EvidencePacketBuilder)
      expect(default_planner.instance_variable_get(:@family_repository)).to be_a(Marine::Catalog::ProductFamilyRepository)
      expect(default_planner.instance_variable_get(:@variant_resolver)).to be_a(Marine::Catalog::VariantResolver)
      expect(default_planner.instance_variable_get(:@price_repository)).to be_a(Marine::Catalog::PriceRepository)
      expect(default_planner.instance_variable_get(:@stock_repository)).to be_a(Marine::Catalog::StockRepository)
    end
  end

  describe 'no side-effect collaborators in source' do
    it 'references no presenter/provider/delivery/persistence symbol' do
      # Strip comments (as the isolation spec does) so only executable code is scanned.
      code = Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/acceptance_pipeline_coordinator.rb')
                  .read.gsub(/#(?!\{).*/, '')
      %w[Presenter ResponseGenerator deliver assign ShadowMetricsStore Redis .save! .update! .create!].each do |token|
        expect(code).not_to include(token)
      end
    end
  end

  describe 'Candidate authority and live runtime stay untouched' do
    it 'keeps CandidateGate phase-locked and closed' do
      expect(Marine::ProductAuthority::CandidateGate::PHASE_LOCKED).to be(true)
      expect(Marine::ProductAuthority::CandidateGate.open?(account_id: 1, assistant_id: 1)).to be(false)
    end

    it 'is referenced by no live runtime file' do
      root = Rails.root.join('custom/wijaya/batteries/marine_ai')
      %w[
        app/services/marine/agent/runner.rb
        app/jobs/marine/conversation/response_builder_job.rb
        app/services/marine/catalog/product_query_orchestrator.rb
      ].each do |relative|
        path = root.join(relative)
        next unless File.exist?(path)

        source = path.read
        expect(source).not_to include('AcceptancePipelineCoordinator')
        expect(source).not_to include('AcceptanceCaseResult')
      end
    end
  end
end
