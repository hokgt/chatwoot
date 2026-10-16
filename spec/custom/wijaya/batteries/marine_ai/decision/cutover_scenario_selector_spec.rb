# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 6 — the CONTROLLED cutover scenario-selection wrapper. Every dependency (gate,
# Decision Runner, legacy selector, ScenarioAdapter, ScenarioResolver) is injected so no live
# config/Redis/provider/DB is touched. These examples pin: the closed path (blank query or a closed
# gate) runs the legacy selector directly and NEVER touches the adapter/runner/resolver; the open
# path accepts the Decision choice ONLY when the plan is canonical-normalized, both confidences are
# medium/high, a candidate key is present, and the resolver re-resolves it; every other outcome
# falls back to legacy; the legacy selector and the Decision Runner each run AT MOST once; the
# Decision Runner receives message=query, state={}, and a bounded role/content context (no candidate
# intents/slots/values); and the safe notification carries only ids + source/reason and never
# affects the selection.
RSpec.describe Marine::Decision::CutoverScenarioSelector do
  let(:assistant) { double('assistant', id: 3) }
  let(:legacy_scenario) { double('legacy_scenario', id: 11) }
  let(:decision_scenario) { double('decision_scenario', id: 22) }

  let(:gate) { instance_double(Marine::Decision::CutoverGate) }
  let(:runner) { instance_double(Marine::Decision::Runner) }
  let(:legacy_selector) { instance_double(Marine::Agent::ScenarioSelector) }
  let(:adapter) { instance_double(Marine::Decision::ScenarioAdapter) }
  let(:resolver) { instance_double(Marine::Decision::ScenarioResolver) }
  let(:adapter_class) { double('adapter_class') }
  let(:resolver_class) { double('resolver_class') }

  let(:scenario_seam) { [{ 'key' => 'scenario_22', 'description' => 'Stock', 'instruction' => 'x', 'capabilities' => [] }] }

  def build
    described_class.new(assistant: assistant, account_id: 7, gate: gate, decision_runner: runner,
                        legacy_selector: legacy_selector, resolver_class: resolver_class, adapter_class: adapter_class)
  end

  def plan(overrides = {})
    {
      schema_version: Marine::Decision::Schema::SCHEMA_VERSION,
      scenario_candidate: overrides.fetch(:scenario_candidate, { key: 'scenario_22', confidence: 'high' }),
      intents: overrides.fetch(:intents, []),
      slot_operations: overrides.fetch(:slot_operations, []),
      customer_language: nil,
      confidence: overrides.fetch(:confidence, 'high'),
      reason: overrides.fetch(:reason, Marine::Decision::Schema::REASON_NORMALIZED)
    }
  end

  before do
    allow(gate).to receive(:open?).and_return(true)
    allow(legacy_selector).to receive(:select).and_return(legacy_scenario)
    allow(adapter_class).to receive(:new).with(assistant: assistant).and_return(adapter)
    allow(resolver_class).to receive(:new).with(assistant: assistant).and_return(resolver)
    allow(adapter).to receive(:overflow?).and_return(false)
    allow(adapter).to receive(:scenarios).and_return(scenario_seam)
    allow(runner).to receive(:call).and_return(plan)
    allow(resolver).to receive(:resolve).with('scenario_22').and_return(decision_scenario)
  end

  describe 'closed path (legacy directly, no decision work)' do
    it 'uses the legacy selector for a blank query and never touches the gate/adapter/runner' do
      selection = build.select('')

      expect(selection.scenario).to eq(legacy_scenario)
      expect(selection.source).to eq('legacy')
      expect(selection.reason).to eq('blank_query')
      expect(gate).not_to have_received(:open?)
      expect(adapter_class).not_to have_received(:new)
      expect(runner).not_to have_received(:call)
    end

    it 'uses the legacy selector when the gate is closed and never touches the adapter/runner/resolver' do
      allow(gate).to receive(:open?).and_return(false)

      selection = build.select('where is my order')

      expect(selection.scenario).to eq(legacy_scenario)
      expect(selection.source).to eq('legacy')
      expect(selection.reason).to eq('gate_closed')
      expect(legacy_selector).to have_received(:select).with('where is my order').once
      expect(adapter_class).not_to have_received(:new)
      expect(runner).not_to have_received(:call)
      expect(resolver_class).not_to have_received(:new)
    end
  end

  describe 'open path — accepted decision' do
    it 'returns the resolved decision scenario and NEVER runs the legacy selector' do
      selection = build.select('stock for impeller')

      expect(selection.scenario).to eq(decision_scenario)
      expect(selection.source).to eq('decision')
      expect(selection.reason).to eq('decision_accepted')
      expect(selection).to be_frozen
      expect(legacy_selector).not_to have_received(:select)
    end

    it 'calls the Decision Runner exactly once with message=query, state={}, and the adapter scenarios' do
      build.select('stock for impeller')

      expect(runner).to have_received(:call).once.with(
        message: 'stock for impeller', scenarios: scenario_seam, context: [], state: {}
      )
    end

    %w[medium high].each do |level|
      it "accepts a #{level} overall and candidate confidence" do
        allow(runner).to receive(:call).and_return(
          plan(confidence: level, scenario_candidate: { key: 'scenario_22', confidence: level })
        )
        expect(build.select('q').source).to eq('decision')
      end
    end
  end

  describe 'open path — fallback to legacy' do
    def expect_fallback(reason)
      selection = build.select('q')
      expect(selection.source).to eq('legacy')
      expect(selection.reason).to eq(reason)
      expect(selection.scenario).to eq(legacy_scenario)
      expect(legacy_selector).to have_received(:select).once
    end

    it 'falls back when the scenario seam overflows (and never calls the runner)' do
      allow(adapter).to receive(:overflow?).and_return(true)
      expect_fallback('scenario_seam_overflow')
      expect(runner).not_to have_received(:call)
    end

    it 'falls back when the scenario seam is empty (and never calls the runner)' do
      allow(adapter).to receive(:scenarios).and_return([])
      expect_fallback('scenario_seam_empty')
      expect(runner).not_to have_received(:call)
    end

    it 'falls back on an unknown (non-normalized) plan' do
      allow(runner).to receive(:call).and_return(plan(reason: 'timeout'))
      expect_fallback('plan_not_normalized')
    end

    it 'falls back on a wrong schema_version' do
      allow(runner).to receive(:call).and_return(plan.merge(schema_version: 'marine_decision_v999'))
      expect_fallback('plan_not_normalized')
    end

    it 'falls back on a non-hash (malformed) plan' do
      allow(runner).to receive(:call).and_return('not a plan')
      expect_fallback('plan_not_normalized')
    end

    it 'falls back on a low overall confidence' do
      allow(runner).to receive(:call).and_return(plan(confidence: 'low'))
      expect_fallback('plan_low_confidence')
    end

    it 'falls back on a low scenario_candidate confidence' do
      allow(runner).to receive(:call).and_return(plan(scenario_candidate: { key: 'scenario_22', confidence: 'low' }))
      expect_fallback('plan_low_confidence')
    end

    it 'falls back on a nil candidate key' do
      allow(runner).to receive(:call).and_return(plan(scenario_candidate: { key: nil, confidence: 'high' }))
      expect_fallback('plan_no_scenario_candidate')
    end

    it 'falls back on a resolver miss (key does not re-resolve to an enabled scenario)' do
      allow(resolver).to receive(:resolve).with('scenario_22').and_return(nil)
      expect_fallback('resolver_miss')
    end

    it 'falls back on a provider-error fallback plan from the runner' do
      allow(runner).to receive(:call).and_return(Marine::Decision::CandidatePlan.unknown('provider_error'))
      expect_fallback('plan_not_normalized')
    end

    it 'falls back on any runner exception (never raises)' do
      allow(runner).to receive(:call).and_raise(StandardError, 'boom')
      expect_fallback('error')
    end
  end

  # A decision-side failure is swallowed and folds to legacy, but a LEGACY selector failure must NOT
  # be swallowed: it has to propagate so Marine::Agent::Runner#run degrades to the historical safe
  # handoff, exactly as before Stage 6 when this seam called the legacy selector directly.
  describe 'legacy selector failure preserves the Agent::Runner fail-safe (not swallowed)' do
    it 'propagates a closed-path legacy selector error and never touches the decision runner/adapter/resolver' do
      allow(gate).to receive(:open?).and_return(false)
      boom = RuntimeError.new('legacy boom')
      allow(legacy_selector).to receive(:select).and_raise(boom)

      expect { build.select('where is my order') }.to raise_error(boom)
      expect(legacy_selector).to have_received(:select).once
      expect(adapter_class).not_to have_received(:new)
      expect(runner).not_to have_received(:call)
      expect(resolver_class).not_to have_received(:new)
    end

    it 'propagates a legacy selector error even on the open-path decision fallback branch' do
      allow(runner).to receive(:call).and_raise(StandardError, 'decision boom') # decision-side error -> legacy fallback
      boom = RuntimeError.new('legacy boom')
      allow(legacy_selector).to receive(:select).and_raise(boom)

      expect { build.select('stock for impeller') }.to raise_error(boom)
      expect(legacy_selector).to have_received(:select).once
    end
  end

  describe 'candidate intents/slots are never used to drive selection' do
    it 'ignores populated intents/slot_operations and returns only the resolved scenario' do
      allow(runner).to receive(:call).and_return(
        plan(intents: %w[price stock], slot_operations: [{ operation: 'set', slot: 'product' }])
      )

      selection = build.select('q')

      expect(selection.scenario).to eq(decision_scenario)
      expect(selection.source).to eq('decision')
    end

    it 'always passes an empty state (no invented/forwarded product facts) to the runner' do
      build.select('q')
      expect(runner).to have_received(:call).with(hash_including(state: {}))
    end
  end

  describe 'bounded context' do
    it 'forwards only the last 10 valid role/content turns as owned string-keyed hashes' do
      history = (1..15).map { |i| { role: i.even? ? 'assistant' : 'user', content: "turn #{i}" } }
      history << { role: 'system', content: 'dropped' }       # invalid role dropped
      history << { role: 'user', content: '' }                # blank content dropped
      history << 'not a hash'                                 # non-hash dropped

      captured = nil
      allow(runner).to receive(:call) do |**kwargs|
        captured = kwargs[:context]
        plan
      end

      build.select('q', context: history)

      expect(captured.length).to eq(10)
      expect(captured).to all(include('role', 'content'))
      expect(captured.map { |e| e['role'] }.uniq - %w[user assistant]).to be_empty
      expect(captured.none? { |e| e['content'] == 'dropped' || e['content'] == '' }).to be(true)
    end
  end

  describe 'at-most-once execution' do
    it 'runs the Decision Runner at most once and the legacy selector zero times on acceptance' do
      build.select('q')
      expect(runner).to have_received(:call).once
      expect(legacy_selector).to have_received(:select).exactly(0).times
    end

    it 'runs the legacy selector at most once and the Decision Runner zero times when gate closed' do
      allow(gate).to receive(:open?).and_return(false)
      build.select('q')
      expect(legacy_selector).to have_received(:select).once
      expect(runner).to have_received(:call).exactly(0).times
    end
  end

  describe 'notification (privacy + failure isolation)' do
    it 'emits only ids + source/reason and never the raw query' do
      events = []
      callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }

      ActiveSupport::Notifications.subscribed(callback, described_class::NOTIFICATION) do
        build.select('super secret customer text')
      end

      expect(events.size).to eq(1)
      payload = events.first.payload
      expect(payload.keys).to match_array(%i[account_id assistant_id scenario_id source reason])
      expect(payload).to include(account_id: 7, assistant_id: 3, scenario_id: 22, source: 'decision', reason: 'decision_accepted')
      expect(payload.values).not_to include('super secret customer text')
    end

    it 'still returns the selection when the notification itself raises' do
      allow(ActiveSupport::Notifications).to receive(:instrument).and_raise(StandardError, 'bus down')
      expect { build.select('q') }.not_to raise_error
      expect(build.select('q').source).to eq('decision')
    end
  end
end
