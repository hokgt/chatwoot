# frozen_string_literal: true

require 'rails_helper'

# Phase 1 (Opsi B) — the Product Authority Seam adapter. It maps an untrusted, normalized
# marine_decision_v1 candidate plan into the existing backend-owned product-intent input. Execution
# authorization is backend-policy-owned (Marine::Backend::ExecutionPolicy): the carried intents must
# be the exact executable array (Phase 1: ["price"]); scenario carries provenance only ({ key: }).
# Nothing here touches a provider, settings, the runner, the catalog, or any state; all
# product/variant strings are SYNTHETIC candidates.
RSpec.describe Marine::Backend::CandidatePlanToProductIntentAdapter do
  subject(:adapter) { described_class.new }

  def op(operation, slot, candidate = nil)
    value = candidate && { 'raw_candidate' => candidate[0], 'candidate_type' => candidate[1] }
    { 'operation' => operation, 'slot' => slot, 'value' => value }
  end

  def raw_plan(overrides = {})
    {
      'schema_version' => 'marine_decision_v1',
      'scenario_candidate' => { 'key' => 'scenario_8', 'confidence' => 'high' },
      'intents' => ['price'],
      'slot_operations' => [op('set', 'product', %w[Santorini display_name])],
      'customer_language' => 'id',
      'confidence' => 'medium'
    }.merge(overrides)
  end

  def plan(overrides = {})
    Marine::Decision::CandidatePlan.normalize(raw_plan(overrides))
  end

  describe 'accepted plans' do
    it 'maps the authorized price intent and typed slots into the backend-owned product-intent input' do
      result = adapter.call(
        plan: plan('intents' => %w[price],
                   'slot_operations' => [op('set', 'product', %w[Santorini display_name]),
                                         op('set', 'variant_input', %w[BD-4 variant_code])]),
        scenario_key: 'scenario_8'
      )

      expect(result.ok?).to be(true)
      expect(result.intents).to eq(%w[price])
      expect(result.scenario).to eq(key: 'scenario_8')
      expect(result.scenario).not_to have_key(:capabilities)
      expect(result.product_intent).to include(
        product_related: true, intent: 'price', requested_intents: %w[price],
        family_mention: 'Santorini', explicit_child_code: 'BD-4', attribute_candidates: [],
        requires_exact_variant: true, customer_language: 'id', clarification_reply: nil, quantity_inquiry: false
      )
    end

    it 'is deeply immutable (provenance-only frozen scenario)' do
      result = adapter.call(plan: plan, scenario_key: 'scenario_8')

      expect(result.product_intent).to be_frozen
      expect(result.scenario).to be_frozen
      expect(result.scenario).to eq(key: 'scenario_8')
      expect { result.product_intent[:family_mention] << 'x' }.to raise_error(FrozenError)
    end
  end

  describe 'exact-code-only variant authority (3A-1)' do
    it 'never promotes a display_label / attribute_value candidate to an executable candidate' do
      %w[display_label attribute_value].each do |type|
        result = adapter.call(
          plan: plan('intents' => %w[price],
                     'slot_operations' => [op('set', 'product', %w[Santorini display_name]),
                                           op('set', 'variant_input', ['Blue', type])]),
          scenario_key: 'scenario_8'
        )

        # The typed operation stays VISIBLE but is never an executable child code or attribute.
        expect(result.operations).to include(operation: 'set', slot: 'variant_input',
                                             candidate: { raw_candidate: 'Blue', candidate_type: type })
        expect(result.product_intent[:explicit_child_code]).to be_nil
        expect(result.product_intent[:attribute_candidates]).to eq([])
      end
    end

    it 'promotes ONLY a variant_code candidate to the explicit child code' do
      result = adapter.call(
        plan: plan('intents' => %w[price],
                   'slot_operations' => [op('set', 'product', %w[Santorini display_name]),
                                         op('set', 'variant_input', %w[BD-4 variant_code])]),
        scenario_key: 'scenario_8'
      )
      expect(result.product_intent[:explicit_child_code]).to eq('BD-4')
      expect(result.product_intent[:attribute_candidates]).to eq([])
    end
  end

  describe 'execution-policy authorization (exact ["price"]; backend-owned, not scenario-derived)' do
    it 'fails closed on a supported-but-unauthorized single intent (stock)' do
      result = adapter.call(plan: plan('intents' => %w[stock], 'slot_operations' => []), scenario_key: 'scenario_8')

      expect(result.ok?).to be(false)
      expect(result.reason).to eq('phase_not_executable')
      expect(result.product_intent).to be_nil
    end

    it 'fails closed on a supported mixed price+stock set (never a partial product action)' do
      result = adapter.call(plan: plan('intents' => %w[price stock], 'slot_operations' => []), scenario_key: 'scenario_8')

      expect(result.ok?).to be(false)
      expect(result.reason).to eq('phase_not_executable')
      expect(result.product_intent).to be_nil
    end

    it 'fails closed on a supported-but-unauthorized catalog intent' do
      result = adapter.call(plan: plan('intents' => %w[catalog], 'slot_operations' => []), scenario_key: 'scenario_8')

      expect(result.reason).to eq('phase_not_executable')
    end
  end

  describe 'Phase 3 — single listing / information authorization' do
    it 'accepts ["product_listing"] and carries the (untrusted) product candidate, no variant required' do
      result = adapter.call(
        plan: plan('intents' => %w[product_listing],
                   'slot_operations' => [op('set', 'product', %w[Santorini display_name])]),
        scenario_key: 'scenario_8'
      )

      expect(result.ok?).to be(true)
      expect(result.intents).to eq(%w[product_listing])
      expect(result.product_intent).to include(
        product_related: true, intent: 'product_listing', requested_intents: [],
        family_mention: 'Santorini', requires_exact_variant: false
      )
    end

    it 'accepts ["product_information"] with NO product slot (a broad listing, family_mention nil)' do
      result = adapter.call(plan: plan('intents' => %w[product_information], 'slot_operations' => []), scenario_key: 'scenario_8')

      expect(result.ok?).to be(true)
      expect(result.intents).to eq(%w[product_information])
      expect(result.product_intent[:family_mention]).to be_nil
      expect(result.product_intent[:intent]).to eq('product_information')
    end

    it 'fails closed on a listing intent mixed with price (never a partial product action)' do
      result = adapter.call(plan: plan('intents' => %w[price product_listing], 'slot_operations' => []), scenario_key: 'scenario_8')

      expect(result.ok?).to be(false)
      expect(result.reason).to eq('phase_not_executable')
      expect(result.product_intent).to be_nil
    end
  end

  describe 'fail-closed rejections' do
    it 'rejects a malformed / non-hash plan' do
      expect(adapter.call(plan: 'nope', scenario_key: 'scenario_8').reason).to eq('unsupported_schema')
    end

    it 'rejects an oversized intents array (existing normalizer contract)' do
      oversized = raw_plan('intents' => Array.new(40, 'price'))
      expect(adapter.call(plan: oversized, scenario_key: 'scenario_8').reason).to eq('unsupported_schema')
    end

    it 'rejects a duplicate slot mutation (existing normalizer contract)' do
      dup = raw_plan('slot_operations' => [op('set', 'product', %w[A display_name]),
                                           op('replace', 'product', %w[B display_name])])
      expect(adapter.call(plan: dup, scenario_key: 'scenario_8').reason).to eq('unsupported_schema')
    end

    it 'rejects an unresolved / malformed selected scenario key' do
      expect(adapter.call(plan: plan, scenario_key: 'Scenario-8!').reason).to eq('unresolved_scenario')
    end

    it 'rejects a plan nominating a DIFFERENT scenario than the one selected' do
      result = adapter.call(
        plan: plan('scenario_candidate' => { 'key' => 'scenario_5', 'confidence' => 'high' }),
        scenario_key: 'scenario_8'
      )
      expect(result.reason).to eq('scenario_mismatch')
      expect(result.product_intent).to be_nil
    end

    it 'rejects a plan nominating NO scenario when a scenario was selected' do
      result = adapter.call(
        plan: plan('scenario_candidate' => { 'confidence' => 'high' }),
        scenario_key: 'scenario_8'
      )
      expect(result.reason).to eq('scenario_mismatch')
    end

    it 'rejects a plan whose only intents are unsupported for product execution' do
      result = adapter.call(
        plan: plan('intents' => %w[order_status], 'slot_operations' => []),
        scenario_key: 'scenario_8'
      )
      expect(result.reason).to eq('unsupported_intent')
    end

    it 'rejects the WHOLE plan when a supported intent is mixed with an unsupported one' do
      result = adapter.call(
        plan: plan('intents' => %w[price order_status], 'slot_operations' => []),
        scenario_key: 'scenario_8'
      )
      expect(result.reason).to eq('unsupported_intent')
      expect(result.product_intent).to be_nil
    end
  end

  describe 'set / replace / clear operations' do
    it 'carries a replace operation candidate through' do
      result = adapter.call(
        plan: plan('slot_operations' => [op('replace', 'product', %w[BD-3 family_code])]),
        scenario_key: 'scenario_8'
      )
      expect(result.operations).to eq([{ operation: 'replace', slot: 'product',
                                         candidate: { raw_candidate: 'BD-3', candidate_type: 'family_code' } }])
      expect(result.product_intent[:family_mention]).to eq('BD-3')
    end

    it 'records a clear operation with no positive candidate' do
      result = adapter.call(
        plan: plan('slot_operations' => [op('set', 'product', %w[Santorini display_name]),
                                         op('clear', 'variant_input')]),
        scenario_key: 'scenario_8'
      )
      clear = result.operations.find { |o| o[:slot] == 'variant_input' }
      expect(clear).to eq(operation: 'clear', slot: 'variant_input', candidate: nil)
      expect(result.product_intent[:explicit_child_code]).to be_nil
    end
  end

  it 'never carries a validated fact or Model 1 prose' do
    result = adapter.call(plan: plan, scenario_key: 'scenario_8')
    # No validated_variant/family/price/stock/action keys, and no free-text directive.
    expect(result.product_intent.keys).to contain_exactly(
      :product_related, :intent, :requested_intents, :family_mention, :explicit_child_code,
      :attribute_candidates, :requires_exact_variant, :clarification_reply, :family_changed,
      :intent_changed, :intent_scope, :multiple_numeric_candidates, :quantity_inquiry,
      :unsupported_request, :confidence, :customer_language, :reason
    )
    expect(result.product_intent[:clarification_reply]).to be_nil
  end
end
