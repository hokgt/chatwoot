# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 3 — the ISOLATED, UNWIRED Decision Runner. These examples drive both
# protocols end-to-end with an INJECTED settings object, client double, and INJECTED
# classification vocabulary (no real network — WebMock blocks it suite-wide), and pin:
# canonical deep-frozen CandidatePlan output; restriction of proposed intents to the injected
# classification vocabulary; the always-empty Decisions slot rule; the allowlisted unknown-reason
# folding for every failure (incl. an invalid/missing injected vocabulary); that the runner never
# raises; that it reads only the decision-maker settings; and — by source scan — that it references
# no Agent::Runner / ScenarioSelector / DB / reply / state-mutation collaborator. All
# product/scenario strings are SYNTHETIC.
RSpec.describe Marine::Decision::Runner do
  subject(:runner) { described_class.new(client: client, settings: settings, classification_intents: classification) }

  let(:settings) { instance_double(Marine::Llm::SettingsStore, api_mode: 'chat_completions') }
  let(:client) { instance_double(Marine::Decision::Client) }
  # A multi-intent test vocabulary (the Runner is generic: it restricts to WHATEVER the composition
  # root injects; Phase 1 production injects ExecutionPolicy::CLASSIFICATION_INTENTS == price/unsupported).
  let(:classification) { %w[price stock catalog unsupported] }

  def scenarios
    [{ 'key' => 'stock_check', 'description' => 'availability', 'instruction' => 'check' }]
  end

  def run(overrides = {})
    runner.call(message: 'Do you have the vase in stock?', scenarios: scenarios, **overrides)
  end

  def chat_plan(overrides = {})
    JSON.generate({
      'schema_version' => 'marine_decision_v1',
      'scenario_candidate' => { 'key' => 'stock_check', 'confidence' => 'high' },
      'intents' => %w[stock], 'slot_operations' => [], 'customer_language' => 'en', 'confidence' => 'high'
    }.merge(overrides))
  end

  def chat_ok(payload)
    Marine::Decision::TransportResult.success(payload: payload, model: 'm', api_mode: 'chat_completions')
  end

  def decisions_ok(payload)
    Marine::Decision::TransportResult.success(payload: payload, model: 'm', api_mode: 'openrouter_decisions')
  end

  describe 'chat_completions end-to-end' do
    it 'returns a canonical, deep-frozen candidate plan' do
      allow(client).to receive(:call).and_return(chat_ok(chat_plan))
      result = run

      expect(result[:schema_version]).to eq('marine_decision_v1')
      expect(result[:scenario_candidate]).to eq(key: 'stock_check', confidence: 'high')
      expect(result[:intents]).to eq(%w[stock])
      expect(result[:reason]).to eq('normalized')
      expect(result).to be_frozen
      expect(result[:scenario_candidate]).to be_frozen
    end

    it 'restricts proposed intents to the injected classification vocabulary (drops the rest)' do
      allow(client).to receive(:call).and_return(chat_ok(chat_plan('intents' => %w[stock order_status])))
      # order_status is not in the injected vocabulary -> dropped; stock survives.
      expect(run[:intents]).to eq(%w[stock])
    end

    it 'drops a stock intent entirely under a narrow price-only injected vocabulary' do
      price_only = described_class.new(client: client, settings: settings, classification_intents: %w[price unsupported])
      allow(client).to receive(:call).and_return(chat_ok(chat_plan('intents' => %w[stock])))
      result = price_only.call(message: 'Do you have the vase in stock?', scenarios: scenarios)
      expect(result[:intents]).to eq([])
      expect(result[:scenario_candidate][:key]).to eq('stock_check')
    end

    # The candidate key 'ghost_scenario' is well-formed (it matches SCENARIO_KEY_PATTERN, so
    # the normalizer alone would ACCEPT it) but was never supplied. The runtime allowlist —
    # not the JSON schema — folds it to malformed_response, for both the structured-Hash and
    # the JSON-String chat payload shapes.
    it 'folds a chat Hash whose scenario key was not supplied to malformed_response' do
      hash_payload = JSON.parse(chat_plan('scenario_candidate' => { 'key' => 'ghost_scenario', 'confidence' => 'high' }))
      allow(client).to receive(:call).and_return(chat_ok(hash_payload))
      expect(run[:reason]).to eq('malformed_response')
    end

    it 'folds a chat JSON String whose scenario key was not supplied to malformed_response' do
      allow(client).to receive(:call).and_return(chat_ok(chat_plan('scenario_candidate' => { 'key' => 'ghost_scenario', 'confidence' => 'high' })))
      expect(run[:reason]).to eq('malformed_response')
    end
  end

  describe 'openrouter_decisions end-to-end' do
    let(:settings) { instance_double(Marine::Llm::SettingsStore, api_mode: 'openrouter_decisions') }

    # A COMPLETE answer envelope: the scenario choice plus a NOUL answer for EVERY asked
    # intent (allowed_intents = the INJECTED price/stock/catalog/unsupported vocabulary). Only
    # stock clears the threshold.
    let(:answers) do
      {
        'scenario_candidate' => { 'type' => 'choice', 'choice' => 'stock_check', 'confidence' => 0.9,
                                  'probabilities' => { 'stock_check' => 0.9 } },
        'mdq_intent__price' => { 'type' => 'noul', 'noul' => 0.1 },
        'mdq_intent__stock' => { 'type' => 'noul', 'noul' => 0.8 },
        'mdq_intent__catalog' => { 'type' => 'noul', 'noul' => 0.1 },
        'mdq_intent__unsupported' => { 'type' => 'noul', 'noul' => 0.1 }
      }
    end

    it 'maps typed answers into a plan with empty slot_operations and nil language' do
      allow(client).to receive(:call).and_return(decisions_ok(answers))
      result = run

      expect(result[:scenario_candidate]).to eq(key: 'stock_check', confidence: 'high')
      expect(result[:intents]).to eq(%w[stock])
      expect(result[:slot_operations]).to eq([])
      expect(result[:customer_language]).to be_nil
    end

    it 'folds a non-Hash (free-text-shaped) decisions payload to unsupported_schema' do
      allow(client).to receive(:call).and_return(decisions_ok('free text'))
      expect(run[:reason]).to eq('unsupported_schema')
    end
  end

  # Step 3A boundary: the deployed defect classified `Produk apa saja yang tersedia`
  # ("what products are available") — a pure product LISTING turn — as BOTH product_listing
  # and product_information, which fails ExecutionPolicy.product_authorized? (single-intent
  # only) and drops to legacy fallback. These examples drive the fixed protocol end-to-end.
  describe 'Step 3A product_listing / product_information boundary (openrouter_decisions)' do
    let(:settings) { instance_double(Marine::Llm::SettingsStore, api_mode: 'openrouter_decisions') }
    let(:classification) { %w[product_listing product_information price unsupported] }

    def product_scenarios
      [{ 'key' => 'product_scenario', 'description' => 'product catalog', 'instruction' => 'read catalog' }]
    end

    def product_answers(listing:, information:)
      {
        'scenario_candidate' => { 'type' => 'choice', 'choice' => 'product_scenario', 'confidence' => 0.9,
                                  'probabilities' => { 'product_scenario' => 0.9 } },
        'mdq_intent__product_listing' => { 'type' => 'noul', 'noul' => listing },
        'mdq_intent__product_information' => { 'type' => 'noul', 'noul' => information },
        'mdq_intent__price' => { 'type' => 'noul', 'noul' => 0.0 },
        'mdq_intent__unsupported' => { 'type' => 'noul', 'noul' => 0.0 }
      }
    end

    it 'classifies "Produk apa saja yang tersedia" as exactly [product_listing] (packet-authorized)' do
      allow(client).to receive(:call).and_return(decisions_ok(product_answers(listing: 0.82, information: 0.63)))
      result = runner.call(message: 'Produk apa saja yang tersedia', scenarios: product_scenarios)
      expect(result[:intents]).to eq(%w[product_listing])
      expect(Marine::Backend::ExecutionPolicy.product_authorized?(result[:intents])).to be(true)
    end

    it 'keeps a genuine description request as exactly [product_information] (packet-authorized)' do
      allow(client).to receive(:call).and_return(decisions_ok(product_answers(listing: 0.6, information: 0.88)))
      result = runner.call(message: 'Jelaskan produk kain yang tersedia', scenarios: product_scenarios)
      expect(result[:intents]).to eq(%w[product_information])
      expect(Marine::Backend::ExecutionPolicy.product_authorized?(result[:intents])).to be(true)
    end

    it 'never yields the mutually-exclusive pair, so the packet path is never defeated' do
      allow(client).to receive(:call).and_return(decisions_ok(product_answers(listing: 0.9, information: 0.9)))
      result = runner.call(message: 'Produk apa saja yang tersedia', scenarios: product_scenarios)
      expect(result[:intents]).not_to eq(%w[product_listing product_information])
    end
  end

  describe 'aggregate request-byte guard (Stage 2 transport is final)' do
    # An in-contract but MAXED input (20 scenarios × 500-char summaries + a 2000-char message)
    # serializes past the Decisions transport's aggregate request-byte budget (32_000). The
    # REAL transport client rejects it BEFORE any network call and returns a malformed_response
    # failure; the runner folds that to a safe unknown plan and never raises (WebMock would
    # raise if any network were attempted). The runner never truncates and owns no byte guard.
    it 'folds an in-contract but aggregate-oversized decisions request to malformed_response' do
      real_client = Marine::Decision::OpenrouterDecisionsClient.new(model: 'm', endpoint: 'https://example.test', api_key: 'k')
      decisions_settings = instance_double(Marine::Llm::SettingsStore, api_mode: 'openrouter_decisions')
      big_runner = described_class.new(client: real_client, settings: decisions_settings,
                                       classification_intents: %w[price stock catalog unsupported])

      big_summary = 'd' * 500
      big_scenarios = Array.new(20) do |i|
        { 'key' => "scenario_#{i}", 'description' => big_summary, 'instruction' => big_summary }
      end
      result = nil
      expect { result = big_runner.call(message: 'x' * 2000, scenarios: big_scenarios) }.not_to raise_error
      expect(result[:reason]).to eq('malformed_response')
    end
  end

  describe 'transport failure folding' do
    %w[unconfigured timeout provider_error malformed_response].each do |reason|
      it "folds a #{reason} transport failure to that unknown reason" do
        allow(client).to receive(:call).and_return(Marine::Decision::TransportResult.failure(reason: reason, api_mode: 'chat_completions'))
        result = run
        expect(result[:reason]).to eq(reason)
        expect(result[:scenario_candidate][:key]).to be_nil
        expect(result[:intents]).to eq([])
      end
    end

    it 'folds an unknown transport reason to provider_error' do
      allow(client).to receive(:call).and_return({ ok: false, error_reason: 'something_weird', payload: nil })
      expect(run[:reason]).to eq('provider_error')
    end
  end

  describe 'malformed provider output' do
    it 'folds fenced / duplicate-key / wrong-version chat output to a safe unknown plan' do
      allow(client).to receive(:call).and_return(chat_ok("```json\n#{chat_plan}\n```"))
      expect(run[:reason]).to eq('malformed_response')

      allow(client).to receive(:call).and_return(chat_ok('{"schema_version":"marine_decision_v1","confidence":"low","confidence":"high"}'))
      expect(run[:reason]).to eq('malformed_response')

      allow(client).to receive(:call).and_return(chat_ok(chat_plan('schema_version' => 'other_version')))
      expect(run[:reason]).to eq('unsupported_schema')
    end
  end

  describe 'input, mode, vocabulary, and collaborator failures never raise' do
    it 'folds invalid input to malformed_response without calling the transport' do
      expect(client).not_to receive(:call)
      expect(run(message: '   ')[:reason]).to eq('malformed_response')
      expect(run(scenarios: [])[:reason]).to eq('malformed_response')
    end

    it 'folds a missing / invalid injected classification vocabulary to a safe unknown plan without dispatching' do
      expect(client).not_to receive(:call)
      nil_vocab = described_class.new(client: client, settings: settings, classification_intents: nil)
      bad_vocab = described_class.new(client: client, settings: settings, classification_intents: %w[not_an_intent])
      expect(nil_vocab.call(message: 'hi', scenarios: scenarios)[:reason]).to eq('malformed_response')
      expect(bad_vocab.call(message: 'hi', scenarios: scenarios)[:reason]).to eq('malformed_response')
    end

    it 'folds an unrecognized api_mode to unconfigured without dispatching' do
      allow(settings).to receive(:api_mode).and_return('bogus_mode')
      expect(client).not_to receive(:call)
      expect(run[:reason]).to eq('unconfigured')
    end

    it 'folds a raising settings reader or client to provider_error' do
      allow(settings).to receive(:api_mode).and_raise(StandardError, 'boom')
      expect(run[:reason]).to eq('provider_error')

      allow(settings).to receive(:api_mode).and_return('chat_completions')
      allow(client).to receive(:call).and_raise(StandardError, 'boom')
      expect(run[:reason]).to eq('provider_error')
    end
  end

  describe 'default wiring' do
    it 'defaults to the decision-maker settings and a settings-bound client' do
      expect(Marine::Llm::SettingsStore).to receive(:for).with(:decision_maker).and_return(settings)
      expect(Marine::Decision::Client).to receive(:new).with(settings: settings).and_return(client)
      allow(client).to receive(:call).and_return(chat_ok(chat_plan))

      result = described_class.new(classification_intents: %w[price stock catalog unsupported])
                              .call(message: 'Do you have stock?', scenarios: scenarios)
      expect(result[:reason]).to eq('normalized')
    end
  end

  describe 'isolation / no side effects (source proof)' do
    it 'references no Agent::Runner, ScenarioSelector, DB, reply, or state-mutation collaborator in CODE' do
      dir = Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/decision')
      # Strip comments (from a `#` that is NOT a `#{` interpolation) so the isolation
      # commentary itself — which names these collaborators to say we DON'T use them — is
      # not mistaken for a code reference.
      code = %w[runner request_builder chat_response_parser decisions_response_mapper input_contract]
             .map { |name| File.read(dir.join("#{name}.rb")).gsub(/#(?!\{).*/, '') }.join("\n")

      forbidden = ['Agent::Runner', 'ScenarioSelector', 'ActiveRecord', 'ApplicationRecord', 'InstallationConfig',
                   'Marine::Llm::Config', 'BaseService', '.save', '.update!', 'perform_later', 'perform_now']
      forbidden.each { |token| expect(code).not_to include(token) }
    end
  end
end
