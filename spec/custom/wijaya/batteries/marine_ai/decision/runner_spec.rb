# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 3 — the ISOLATED, UNWIRED Decision Runner. These examples drive both
# protocols end-to-end with an INJECTED settings object and client double (no real
# network — WebMock blocks it suite-wide), and pin: canonical deep-frozen CandidatePlan
# output; capability intersection; the always-empty Decisions slot rule; the allowlisted
# unknown-reason folding for every failure; that the runner never raises; that it reads
# only the decision-maker settings; and — by source scan — that it references no
# Agent::Runner / ScenarioSelector / DB / reply / state-mutation collaborator. All
# product/scenario strings are SYNTHETIC.
RSpec.describe Marine::Decision::Runner do
  subject(:runner) { described_class.new(client: client, settings: settings) }

  let(:settings) { instance_double(Marine::Llm::SettingsStore, api_mode: 'chat_completions') }
  let(:client) { instance_double(Marine::Decision::Client) }

  def scenarios(caps = %w[stock price catalog])
    [{ 'key' => 'stock_check', 'description' => 'availability', 'instruction' => 'check', 'capabilities' => caps }]
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

    it 'intersects proposed intents with the declared capability union' do
      allow(client).to receive(:call).and_return(chat_ok(chat_plan('intents' => %w[stock order_status])))
      # order_status is not a declared capability -> dropped; stock survives.
      expect(run(scenarios: scenarios(%w[stock]))[:intents]).to eq(%w[stock])
    end

    it 'returns empty intents but preserves the candidate scenario when no capability survives' do
      allow(client).to receive(:call).and_return(chat_ok(chat_plan('intents' => %w[stock])))
      result = run(scenarios: scenarios([]))
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
    # intent (allowed_intents = price/stock/catalog/unsupported for these scenarios). Only
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

  describe 'aggregate request-byte guard (Stage 2 transport is final)' do
    # An in-contract but MAXED input (20 scenarios × 500-char summaries + a 2000-char message)
    # serializes past the Decisions transport's aggregate request-byte budget (32_000). The
    # REAL transport client rejects it BEFORE any network call and returns a malformed_response
    # failure; the runner folds that to a safe unknown plan and never raises (WebMock would
    # raise if any network were attempted). The runner never truncates and owns no byte guard.
    it 'folds an in-contract but aggregate-oversized decisions request to malformed_response' do
      real_client = Marine::Decision::OpenrouterDecisionsClient.new(model: 'm', endpoint: 'https://example.test', api_key: 'k')
      decisions_settings = instance_double(Marine::Llm::SettingsStore, api_mode: 'openrouter_decisions')
      big_runner = described_class.new(client: real_client, settings: decisions_settings)

      big_summary = 'd' * 500
      big_scenarios = Array.new(20) do |i|
        { 'key' => "scenario_#{i}", 'description' => big_summary, 'instruction' => big_summary, 'capabilities' => %w[stock price catalog] }
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

  describe 'input, mode, and collaborator failures never raise' do
    it 'folds invalid input to malformed_response without calling the transport' do
      expect(client).not_to receive(:call)
      expect(run(message: '   ')[:reason]).to eq('malformed_response')
      expect(run(scenarios: [])[:reason]).to eq('malformed_response')
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

      expect(described_class.new.call(message: 'Do you have stock?', scenarios: scenarios)[:reason]).to eq('normalized')
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
