# frozen_string_literal: true

require 'rails_helper'

# Step 2 — proof that Model 1 (the ISOLATED, UNWIRED Marine::Decision::Runner) can emit a
# STRUCTURED, product-related candidate plan via the generic chat_completions structured-output
# path, that the plan survives Stage 1 normalization + the injected Phase-1 classification-vocabulary
# restriction WITHOUT losing intents / product+variant slots / language, that every slot value stays
# a RAW untrusted candidate (never a validated fact), and that the resulting plan is structurally
# consumable by Marine::Backend::CandidatePlanToProductIntentAdapter under the backend ExecutionPolicy
# (Phase 1: exactly ["price"]) — all with NO backend/runtime wiring and NO gate/shadow/cutover
# activation.
#
# Discipline mirrors runner_spec: an INJECTED settings object + client double (WebMock blocks the
# network suite-wide), the INJECTED Phase-1 classification vocabulary, and the real backend adapter (a
# PURE object). No DB record, no provider, no repository. Every product/variant/scenario string is
# SYNTHETIC.
RSpec.describe 'Marine Model 1 structured product candidate (Step 2)' do
  # Site D: the Runner is constructed with the policy-derived classification vocabulary so the proof
  # runs over the Phase-1 vocabulary (["price","unsupported"]).
  subject(:runner) do
    Marine::Decision::Runner.new(client: client, settings: settings,
                                 classification_intents: Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS)
  end

  let(:settings) { instance_double(Marine::Llm::SettingsStore, api_mode: 'chat_completions') }
  let(:client) { instance_double(Marine::Decision::Client) }
  let(:adapter) { Marine::Backend::CandidatePlanToProductIntentAdapter.new }

  # The scenario seam the Runner receives: a single product scenario (identity/context only — NO
  # capabilities). scenario_4242 is a SYNTHETIC `scenario_<id>` key (no deployed scenario ID is
  # embedded) in the stable shape the ScenarioAdapter emits.
  def scenarios
    [{ 'key' => 'scenario_4242', 'description' => 'product availability and pricing',
       'instruction' => 'answer product questions' }]
  end

  # A full structured product candidate: a nominated scenario, a product intent, a product
  # family_code candidate + an exact variant_code candidate, and a language hint.
  def product_candidate(overrides = {})
    {
      'schema_version' => 'marine_decision_v1',
      'scenario_candidate' => { 'key' => 'scenario_4242', 'confidence' => 'high' },
      'intents' => %w[price],
      'slot_operations' => [
        { 'operation' => 'set', 'slot' => 'product',
          'value' => { 'raw_candidate' => 'SYN-FAMILY', 'candidate_type' => 'family_code' } },
        { 'operation' => 'set', 'slot' => 'variant_input',
          'value' => { 'raw_candidate' => 'SYN-VARIANT-01', 'candidate_type' => 'variant_code' } }
      ],
      'customer_language' => 'id',
      'confidence' => 'high'
    }.merge(overrides)
  end

  def chat_ok(payload)
    Marine::Decision::TransportResult.success(payload: payload, model: 'm', api_mode: 'chat_completions')
  end

  def returns(raw_hash)
    allow(client).to receive(:call).and_return(chat_ok(JSON.generate(raw_hash)))
  end

  def run(overrides = {})
    runner.call(message: 'SYNTHETIC CUSTOMER INPUT', scenarios: scenarios, **overrides)
  end

  describe 'a valid product candidate normalizes losslessly (proofs #1, #2)' do
    it 'retains intents, both typed slots, and the language through normalization' do
      returns(product_candidate)
      plan = run

      expect(plan[:reason]).to eq('normalized')
      expect(plan[:schema_version]).to eq('marine_decision_v1')
      expect(plan[:scenario_candidate]).to eq(key: 'scenario_4242', confidence: 'high')
      expect(plan[:intents]).to eq(%w[price])
      expect(plan[:customer_language]).to eq('id')
      expect(plan[:slot_operations]).to eq(
        [
          { operation: 'set', slot: 'product', value: { raw_candidate: 'SYN-FAMILY', candidate_type: 'family_code' } },
          { operation: 'set', slot: 'variant_input', value: { raw_candidate: 'SYN-VARIANT-01', candidate_type: 'variant_code' } }
        ]
      )
      expect(plan).to be_frozen
    end

    it 'drops an intent outside the injected classification vocabulary while preserving the slots' do
      # order_status is NOT in the injected Phase-1 vocabulary -> dropped before normalization; the
      # price intent and both product/variant slots survive untouched.
      returns(product_candidate('intents' => %w[price order_status]))
      plan = run

      expect(plan[:intents]).to eq(%w[price])
      expect(plan[:slot_operations].length).to eq(2)
    end
  end

  describe 'the plan is consumable by the backend adapter (proof #6)' do
    it 'is accepted under the ExecutionPolicy (exact price), carrying only raw candidates' do
      returns(product_candidate)
      result = adapter.call(plan: run, scenario_key: 'scenario_4242')

      expect(result.ok?).to be(true)
      expect(result.intents).to eq(%w[price])
      expect(result.scenario).to eq(key: 'scenario_4242')
      # family_mention / explicit_child_code are the RAW candidates verbatim: no repository
      # resolved or validated them (a repository call would have replaced them with a resolved
      # code). clarification_reply stays nil — no Model 1 prose; reason is the extractor contract.
      expect(result.product_intent).to include(
        product_related: true, intent: 'price', requested_intents: %w[price],
        family_mention: 'SYN-FAMILY', explicit_child_code: 'SYN-VARIANT-01',
        attribute_candidates: [], requires_exact_variant: true,
        customer_language: 'id', clarification_reply: nil, reason: 'extracted'
      )
    end
  end

  describe 'slots/candidates stay raw and untrusted (proof #3)' do
    it 'folds a candidate smuggling a top-level authority field to a safe unknown plan' do
      returns(product_candidate.merge('price' => '19.99'))
      expect(run[:reason]).to eq('malformed_response')
    end

    it 'folds a slot value smuggling a validated-authority field to a safe unknown plan' do
      smuggled = product_candidate(
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'variant_input',
            'value' => { 'raw_candidate' => 'SYN-VARIANT-01', 'candidate_type' => 'variant_code',
                         'validated_variant_code' => 'SYN-VARIANT-01' } }
        ]
      )
      returns(smuggled)
      expect(run[:reason]).to eq('malformed_response')
    end

    it 'never promotes a display_label variant candidate to an executable child code' do
      returns(product_candidate(
                'slot_operations' => [
                  { 'operation' => 'set', 'slot' => 'variant_input',
                    'value' => { 'raw_candidate' => 'SYN-LABEL', 'candidate_type' => 'display_label' } }
                ]
              ))
      result = adapter.call(plan: run, scenario_key: 'scenario_4242')

      expect(result.ok?).to be(true)
      expect(result.product_intent[:explicit_child_code]).to be_nil
      expect(result.product_intent[:attribute_candidates]).to eq([])
      # The typed operation stays VISIBLE but remains an untrusted candidate.
      expect(result.operations).to include(
        operation: 'set', slot: 'variant_input', candidate: { raw_candidate: 'SYN-LABEL', candidate_type: 'display_label' }
      )
    end
  end

  describe 'malformed / unknown structured output fails closed (proof #4)' do
    it 'folds an unknown slot candidate_type to malformed_response' do
      returns(product_candidate(
                'slot_operations' => [
                  { 'operation' => 'set', 'slot' => 'product',
                    'value' => { 'raw_candidate' => 'SYN-FAMILY', 'candidate_type' => 'mystery_type' } }
                ]
              ))
      expect(run[:reason]).to eq('malformed_response')
    end

    it 'folds a wrong schema_version to unsupported_schema' do
      returns(product_candidate('schema_version' => 'other_version'))
      expect(run[:reason]).to eq('unsupported_schema')
    end
  end

  describe 'ExecutionPolicy is authoritative and fails closed (proof #5)' do
    it 'rejects a forged non-price (stock) plan at the adapter with phase_not_executable' do
      forged = Marine::Decision::CandidatePlan.normalize(product_candidate('intents' => %w[stock], 'slot_operations' => []))
      result = adapter.call(plan: forged, scenario_key: 'scenario_4242')
      expect(result.ok?).to be(false)
      expect(result.reason).to eq('phase_not_executable')
    end

    it 'rejects a forged mixed price+stock plan at the adapter with phase_not_executable' do
      forged = Marine::Decision::CandidatePlan.normalize(product_candidate('intents' => %w[price stock], 'slot_operations' => []))
      result = adapter.call(plan: forged, scenario_key: 'scenario_4242')
      expect(result.reason).to eq('phase_not_executable')
    end
  end

  describe 'isolation: no gate/shadow/cutover activation or runtime/backend wiring (proof #8)' do
    it 'references no activation gate or live-path collaborator in CODE (comments stripped)' do
      dir = Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine')
      code = %w[decision/runner decision/request_builder decision/chat_response_parser
                decision/input_contract backend/candidate_plan_to_product_intent_adapter]
             .map { |name| File.read(dir.join("#{name}.rb")).gsub(/#(?!\{).*/, '') }.join("\n")

      forbidden = ['CutoverGate', 'CutoverConfig', 'CutoverScenarioSelector', 'CandidateGate',
                   'ShadowEnqueuer', 'ShadowJob', 'ShadowExecution', 'Agent::Runner', 'ResponseBuilderJob',
                   'ProductQueryOrchestrator', 'ProductExecutionPlanner', 'EvidencePacketBuilder',
                   'EvidencePacketPresenter', 'perform_later', 'perform_now']
      forbidden.each { |token| expect(code).not_to include(token) }
    end
  end
end
