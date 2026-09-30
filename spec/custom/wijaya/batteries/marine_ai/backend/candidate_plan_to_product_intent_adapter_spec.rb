# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-1 (isolated / mock-only) — the Product Authority Seam adapter. It maps an untrusted,
# normalized marine_decision_v1 candidate plan into the existing backend-owned product-intent
# input under per-scenario capability authority. Nothing here touches a provider, settings, the
# runner, the catalog, or any state; all product/variant strings are SYNTHETIC candidates.
RSpec.describe Marine::Backend::CandidatePlanToProductIntentAdapter do
  subject(:adapter) { described_class.new }

  let(:capabilities) do
    {
      'scenario_8' => %w[price stock catalog product_overview parent_info],
      'scenario_5' => %w[price catalog]
    }
  end

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
    it 'maps supported intents and typed slots into the backend-owned product-intent input' do
      result = adapter.call(
        plan: plan('intents' => %w[price],
                   'slot_operations' => [op('set', 'product', %w[Santorini display_name]),
                                         op('set', 'variant_input', %w[BD-4 variant_code])]),
        scenario_key: 'scenario_8', scenario_capabilities: capabilities
      )

      expect(result.ok?).to be(true)
      expect(result.intents).to eq(%w[price])
      expect(result.scenario).to eq(key: 'scenario_8', capabilities: %w[price stock catalog product_overview parent_info])
      expect(result.product_intent).to include(
        product_related: true, intent: 'price', requested_intents: %w[price],
        family_mention: 'Santorini', explicit_child_code: 'BD-4', attribute_candidates: [],
        requires_exact_variant: true, customer_language: 'id', clarification_reply: nil, quantity_inquiry: false
      )
    end

    it 'sets requires_exact_variant only for the exact-variant intents (price/stock/variant_info)' do
      price = adapter.call(plan: plan('intents' => %w[price]), scenario_key: 'scenario_8', scenario_capabilities: capabilities)
      catalog = adapter.call(plan: plan('intents' => %w[catalog]), scenario_key: 'scenario_8', scenario_capabilities: capabilities)

      expect(price.product_intent[:requires_exact_variant]).to be(true)
      expect(catalog.product_intent[:requires_exact_variant]).to be(false)
    end

    it 'is deeply immutable' do
      result = adapter.call(plan: plan, scenario_key: 'scenario_8', scenario_capabilities: capabilities)

      expect(result.product_intent).to be_frozen
      expect(result.scenario[:capabilities]).to be_frozen
      expect { result.product_intent[:family_mention] << 'x' }.to raise_error(FrozenError)
    end
  end

  describe 'exact-code-only variant authority (3A-1)' do
    it 'never promotes a display_label / attribute_value candidate to an executable candidate' do
      %w[display_label attribute_value].each do |type|
        result = adapter.call(
          plan: plan('intents' => %w[stock],
                     'slot_operations' => [op('set', 'product', %w[Santorini display_name]),
                                           op('set', 'variant_input', ['Blue', type])]),
          scenario_key: 'scenario_8', scenario_capabilities: capabilities
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
        scenario_key: 'scenario_8', scenario_capabilities: capabilities
      )
      expect(result.product_intent[:explicit_child_code]).to eq('BD-4')
      expect(result.product_intent[:attribute_candidates]).to eq([])
    end
  end

  describe 'combined price+stock' do
    it 'accepts price+stock only on a scenario whose capabilities contain both' do
      result = adapter.call(
        plan: plan('intents' => %w[price stock]),
        scenario_key: 'scenario_8', scenario_capabilities: capabilities
      )

      expect(result.ok?).to be(true)
      expect(result.intents).to eq(%w[price stock])
      expect(result.product_intent[:requested_intents]).to eq(%w[price stock])
    end

    it 'fails closed when the selected scenario lacks a requested capability' do
      result = adapter.call(
        plan: plan('intents' => %w[price stock], 'scenario_candidate' => { 'key' => 'scenario_5', 'confidence' => 'high' }),
        scenario_key: 'scenario_5', scenario_capabilities: capabilities
      )

      expect(result.ok?).to be(false)
      expect(result.reason).to eq('capability_mismatch')
      expect(result.product_intent).to be_nil
    end
  end

  describe 'fail-closed rejections' do
    it 'rejects a malformed / non-hash plan' do
      expect(adapter.call(plan: 'nope', scenario_key: 'scenario_8', scenario_capabilities: capabilities).reason)
        .to eq('unsupported_schema')
    end

    it 'rejects an oversized intents array (existing normalizer contract)' do
      oversized = raw_plan('intents' => Array.new(40, 'price'))
      expect(adapter.call(plan: oversized, scenario_key: 'scenario_8', scenario_capabilities: capabilities).reason)
        .to eq('unsupported_schema')
    end

    it 'rejects a duplicate slot mutation (existing normalizer contract)' do
      dup = raw_plan('slot_operations' => [op('set', 'product', %w[A display_name]),
                                           op('replace', 'product', %w[B display_name])])
      expect(adapter.call(plan: dup, scenario_key: 'scenario_8', scenario_capabilities: capabilities).reason)
        .to eq('unsupported_schema')
    end

    it 'rejects an unresolved / malformed selected scenario key' do
      expect(adapter.call(plan: plan, scenario_key: 'Scenario-8!', scenario_capabilities: capabilities).reason)
        .to eq('unresolved_scenario')
    end

    it 'rejects a plan nominating a DIFFERENT scenario than the one selected' do
      result = adapter.call(
        plan: plan('scenario_candidate' => { 'key' => 'scenario_5', 'confidence' => 'high' }),
        scenario_key: 'scenario_8', scenario_capabilities: capabilities
      )
      expect(result.reason).to eq('scenario_mismatch')
      expect(result.product_intent).to be_nil
    end

    it 'rejects a plan nominating NO scenario when a scenario was selected' do
      result = adapter.call(
        plan: plan('scenario_candidate' => { 'confidence' => 'high' }),
        scenario_key: 'scenario_8', scenario_capabilities: capabilities
      )
      expect(result.reason).to eq('scenario_mismatch')
    end

    it 'rejects when the selected scenario has no configured capabilities' do
      result = adapter.call(
        plan: plan('scenario_candidate' => { 'key' => 'scenario_99', 'confidence' => 'high' }),
        scenario_key: 'scenario_99', scenario_capabilities: capabilities
      )
      expect(result.reason).to eq('capability_unconfigured')
    end

    it 'rejects a malformed capability map (unknown or non-string capability value)' do
      unknown = adapter.call(plan: plan, scenario_key: 'scenario_8',
                             scenario_capabilities: { 'scenario_8' => %w[price not_an_intent] })
      non_string = adapter.call(plan: plan, scenario_key: 'scenario_8',
                                scenario_capabilities: { 'scenario_8' => ['price', 123] })

      expect(unknown.reason).to eq('capability_malformed')
      expect(non_string.reason).to eq('capability_malformed')
    end

    it 'rejects a plan whose only intents are unsupported for product execution' do
      result = adapter.call(
        plan: plan('intents' => %w[order_status], 'slot_operations' => []),
        scenario_key: 'scenario_8', scenario_capabilities: capabilities.merge('scenario_8' => %w[order_status price stock])
      )
      expect(result.reason).to eq('unsupported_intent')
    end

    it 'rejects the WHOLE plan when a supported intent is mixed with an unsupported one' do
      result = adapter.call(
        plan: plan('intents' => %w[price order_status], 'slot_operations' => []),
        scenario_key: 'scenario_8', scenario_capabilities: capabilities.merge('scenario_8' => %w[price stock order_status])
      )
      expect(result.reason).to eq('unsupported_intent')
      expect(result.product_intent).to be_nil
    end
  end

  describe 'set / replace / clear operations' do
    it 'carries a replace operation candidate through' do
      result = adapter.call(
        plan: plan('slot_operations' => [op('replace', 'product', %w[BD-3 family_code])]),
        scenario_key: 'scenario_8', scenario_capabilities: capabilities
      )
      expect(result.operations).to eq([{ operation: 'replace', slot: 'product',
                                         candidate: { raw_candidate: 'BD-3', candidate_type: 'family_code' } }])
      expect(result.product_intent[:family_mention]).to eq('BD-3')
    end

    it 'records a clear operation with no positive candidate' do
      result = adapter.call(
        plan: plan('slot_operations' => [op('set', 'product', %w[Santorini display_name]),
                                         op('clear', 'variant_input')]),
        scenario_key: 'scenario_8', scenario_capabilities: capabilities
      )
      clear = result.operations.find { |o| o[:slot] == 'variant_input' }
      expect(clear).to eq(operation: 'clear', slot: 'variant_input', candidate: nil)
      expect(result.product_intent[:explicit_child_code]).to be_nil
    end
  end

  it 'never carries a validated fact or Model 1 prose' do
    result = adapter.call(plan: plan, scenario_key: 'scenario_8', scenario_capabilities: capabilities)
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
