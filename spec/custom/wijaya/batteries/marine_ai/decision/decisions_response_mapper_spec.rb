# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 3 — the strict Decisions answer mapper. These examples pin the official
# Jev answer shapes (choice + noul), the conservative NOUL threshold and deterministic
# confidence thresholds, the always-empty slot_operations / nil language (Jev cannot
# extract free text), STRICT answer completeness (EXACTLY the scenario question + EVERY
# intent question asked, String keys only), the exact allowed/required fields per answer,
# and fail-closed rejection of unknown/missing/type-confused/duplicate answer shapes,
# non-finite probabilities, and hostile numeric-shaped inputs. All keys are SYNTHETIC.
RSpec.describe Marine::Decision::DecisionsResponseMapper do
  let(:scenario_keys) { %w[stock_check catalog_browse] }
  let(:allowed_intents) { %w[price stock catalog unsupported] }

  def choice(key: 'stock_check', probs: { 'stock_check' => 0.9, 'catalog_browse' => 0.1 }, confidence: 0.9)
    { 'type' => 'choice', 'choice' => key, 'confidence' => confidence, 'probabilities' => probs }
  end

  # A complete NOUL answer set for EVERY asked intent (default below threshold), so the
  # envelope is complete; `overrides` bumps specific intent probabilities.
  def nouls(overrides = {})
    allowed_intents.each_with_object({}) do |intent, acc|
      acc["mdq_intent__#{intent}"] = { 'type' => 'noul', 'noul' => overrides.fetch(intent, 0.0) }
    end
  end

  # A complete, valid answer envelope: the scenario choice + all intent NOUL answers.
  def answers_for(scenario: choice, intents: {})
    { 'scenario_candidate' => scenario }.merge(nouls(intents))
  end

  def map(answers)
    described_class.map(answers, scenario_keys: scenario_keys, allowed_intents: allowed_intents)
  end

  it 'maps a complete choice + noul answer set into a candidate hash (empty slots, nil language)' do
    result = map(answers_for(intents: { 'stock' => 0.8 }))
    expect(result).to eq(
      'schema_version' => 'marine_decision_v1',
      'scenario_candidate' => { 'key' => 'stock_check', 'confidence' => 'high' },
      'intents' => %w[stock],
      'slot_operations' => [],
      'customer_language' => nil,
      'confidence' => 'high'
    )
  end

  it 'selects multiple intents above the threshold in canonical Schema order' do
    result = map(answers_for(intents: { 'stock' => 0.7, 'price' => 0.95 }))
    expect(result['intents']).to eq(%w[price stock])
  end

  it 'drops intents below the conservative threshold, returning [] rather than inventing unknown' do
    result = map(answers_for(intents: { 'stock' => 0.4 }))
    expect(result['intents']).to eq([])
  end

  it 'derives confidence levels deterministically from the selected scenario probability' do
    expect(map(answers_for(scenario: choice(probs: { 'stock_check' => 0.4, 'catalog_browse' => 0.1 })))['confidence']).to eq('low')
    expect(map(answers_for(scenario: choice(probs: { 'stock_check' => 0.6, 'catalog_browse' => 0.1 })))['confidence']).to eq('medium')
    expect(map(answers_for(scenario: choice(probs: { 'stock_check' => 0.8, 'catalog_browse' => 0.1 })))['confidence']).to eq('high')
  end

  # product_listing and product_information are contractually mutually exclusive (names/catalog
  # listing vs an explicit description/explanation request). Independent NOUL questions can both
  # clear the threshold on an overlapping turn; the mapper must enforce the exclusivity over the
  # typed probabilities so ExecutionPolicy's single-intent product authorization is never defeated.
  describe 'product_listing / product_information mutual-exclusivity contract' do
    let(:scenario_keys) { %w[product_scenario] }
    let(:allowed_intents) { %w[product_listing product_information price unsupported] }

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

    it 'keeps only the strictly-higher-probability member when both clear the threshold' do
      expect(map(product_answers(listing: 0.82, information: 0.63))['intents']).to eq(%w[product_listing])
      expect(map(product_answers(listing: 0.62, information: 0.85))['intents']).to eq(%w[product_information])
    end

    it 'never emits both members together, dropping both on an exact tie (fail closed)' do
      expect(map(product_answers(listing: 0.9, information: 0.9))['intents']).to eq([])
    end

    it 'leaves a lone, unambiguous member untouched' do
      expect(map(product_answers(listing: 0.1, information: 0.9))['intents']).to eq(%w[product_information])
      expect(map(product_answers(listing: 0.9, information: 0.1))['intents']).to eq(%w[product_listing])
    end
  end

  describe 'product overview / listing / information mutual-exclusivity contract' do
    let(:scenario_keys) { %w[product_scenario] }
    let(:allowed_intents) { %w[product_overview product_listing product_information unsupported] }

    def offering_answers(overview:, listing:, information: 0.0)
      {
        'scenario_candidate' => { 'type' => 'choice', 'choice' => 'product_scenario', 'confidence' => 0.9,
                                  'probabilities' => { 'product_scenario' => 0.9 } },
        'mdq_intent__product_overview' => { 'type' => 'noul', 'noul' => overview },
        'mdq_intent__product_listing' => { 'type' => 'noul', 'noul' => listing },
        'mdq_intent__product_information' => { 'type' => 'noul', 'noul' => information },
        'mdq_intent__unsupported' => { 'type' => 'noul', 'noul' => 0.0 }
      }
    end

    it 'keeps the more-specific listing when overview and listing both clear the threshold' do
      result = map(offering_answers(overview: 0.61, listing: 0.92))

      expect(result['intents']).to eq(%w[product_listing])
    end

    it 'keeps overview when it is strictly stronger than the scoped listing signal' do
      result = map(offering_answers(overview: 0.93, listing: 0.62))

      expect(result['intents']).to eq(%w[product_overview])
    end

    it 'drops the whole conflicting offering set on an exact tie' do
      result = map(offering_answers(overview: 0.9, listing: 0.9, information: 0.9))

      expect(result['intents']).to eq([])
    end
  end

  # price and price_range are disjoint at the classification contract (specific item vs family-wide
  # span), but they are deliberately NOT in MUTUALLY_EXCLUSIVE_INTENTS: the correct discriminator is
  # the catalog exact-child authority, which is unavailable at the mapper, not a NOUL probability.
  # So the mapper must NEVER silently collapse the pair; when both clear the threshold both survive,
  # which downstream ExecutionPolicy rejects fail-closed (preserved behaviour, no wrong family-range).
  describe 'price / price_range are not collapsed by probability at the mapper' do
    let(:scenario_keys) { %w[product_scenario] }
    let(:allowed_intents) { %w[price price_range stock unsupported] }

    def price_answers(price:, price_range:)
      {
        'scenario_candidate' => { 'type' => 'choice', 'choice' => 'product_scenario', 'confidence' => 0.9,
                                  'probabilities' => { 'product_scenario' => 0.9 } },
        'mdq_intent__price' => { 'type' => 'noul', 'noul' => price },
        'mdq_intent__price_range' => { 'type' => 'noul', 'noul' => price_range },
        'mdq_intent__stock' => { 'type' => 'noul', 'noul' => 0.0 },
        'mdq_intent__unsupported' => { 'type' => 'noul', 'noul' => 0.0 }
      }
    end

    it 'keeps both when both clear the threshold (no silent collapse to price)' do
      expect(map(price_answers(price: 0.9, price_range: 0.7))['intents']).to eq(%w[price price_range])
      expect(map(price_answers(price: 0.7, price_range: 0.9))['intents']).to eq(%w[price price_range])
    end

    it 'leaves a lone member untouched' do
      expect(map(price_answers(price: 0.9, price_range: 0.1))['intents']).to eq(%w[price])
      expect(map(price_answers(price: 0.1, price_range: 0.9))['intents']).to eq(%w[price_range])
    end
  end

  describe 'answer completeness (exactly scenario + every intent question asked)' do
    it 'rejects an envelope missing any asked intent NOUL answer' do
      incomplete = answers_for.except('mdq_intent__catalog')
      expect(map(incomplete)).to be_nil
    end

    it 'rejects a missing scenario answer' do
      expect(map(nouls)).to be_nil
    end

    it 'rejects an unknown / extra answer key' do
      expect(map(answers_for.merge('mdq_intent__unknown_intent' => { 'type' => 'noul', 'noul' => 0.9 }))).to be_nil
    end
  end

  describe 'strict per-answer field contracts' do
    it 'rejects a scenario answer missing the required confidence field' do
      no_conf = { 'type' => 'choice', 'choice' => 'stock_check', 'probabilities' => { 'stock_check' => 0.9 } }
      expect(map(answers_for(scenario: no_conf))).to be_nil
    end

    it 'rejects a scenario answer with an unknown extra field' do
      expect(map(answers_for(scenario: choice.merge('extra' => 1)))).to be_nil
    end

    it 'rejects a non-finite or out-of-range scenario confidence' do
      expect(map(answers_for(scenario: choice(confidence: Float::NAN)))).to be_nil
      expect(map(answers_for(scenario: choice(confidence: 1.5)))).to be_nil
    end

    it 'rejects a Symbol/mixed-keyed scenario answer (JSON-origin String keys only)' do
      sym = { 'type' => 'choice', 'choice' => 'stock_check', 'confidence' => 0.9, :probabilities => { 'stock_check' => 0.9 } }
      expect(map(answers_for(scenario: sym))).to be_nil
    end

    it 'rejects a NOUL answer with an unknown extra field' do
      expect(map(answers_for.merge('mdq_intent__stock' => { 'type' => 'noul', 'noul' => 0.8, 'extra' => 1 }))).to be_nil
    end

    it 'rejects a Symbol-keyed NOUL answer' do
      expect(map(answers_for.merge('mdq_intent__stock' => { 'type' => 'noul', :noul => 0.8 }))).to be_nil
    end
  end

  describe 'fail-closed rejection' do
    it 'rejects a type-confused or foreign-choice scenario answer' do
      expect(map(answers_for(scenario: { 'type' => 'noul', 'noul' => 0.9 }))).to be_nil
      expect(map(answers_for(scenario: choice(key: 'not_a_scenario')))).to be_nil
    end

    it 'rejects probabilities missing the selected choice or keyed by a foreign scenario' do
      expect(map(answers_for(scenario: choice(probs: { 'catalog_browse' => 0.9 })))).to be_nil
      expect(map(answers_for(scenario: choice(probs: { 'stock_check' => 0.9, 'ghost' => 0.1 })))).to be_nil
    end

    it 'rejects a Symbol-keyed probabilities hash' do
      expect(map(answers_for(scenario: choice(probs: { 'stock_check' => 0.9, :catalog_browse => 0.1 })))).to be_nil
    end

    it 'rejects non-finite probabilities (NaN / Infinity) and out-of-range values' do
      expect(map(answers_for(scenario: choice(probs: { 'stock_check' => Float::NAN, 'catalog_browse' => 0.1 })))).to be_nil
      expect(map(answers_for(scenario: choice(probs: { 'stock_check' => Float::INFINITY, 'catalog_browse' => 0.1 })))).to be_nil
      expect(map(answers_for(scenario: choice(probs: { 'stock_check' => 1.5, 'catalog_browse' => 0.1 })))).to be_nil
    end

    it 'rejects a type-confused or out-of-range NOUL intent answer' do
      expect(map(answers_for.merge('mdq_intent__stock' => { 'type' => 'choice', 'noul' => 0.9 }))).to be_nil
      expect(map(answers_for.merge('mdq_intent__stock' => { 'type' => 'noul', 'noul' => 1.5 }))).to be_nil
      expect(map(answers_for.merge('mdq_intent__stock' => { 'type' => 'noul', 'noul' => Float::NAN }))).to be_nil
    end

    it 'rejects a mixed String/Symbol duplicate answer key' do
      expect(map(answers_for.merge(scenario_candidate: choice))).to be_nil
    end

    it 'rejects a non-hash / empty answers payload' do
      expect(map('not a hash')).to be_nil
      expect(map({})).to be_nil
    end

    it 'never raises on a hostile numeric-shaped probability whose comparison raises' do
      hostile = Class.new(Numeric) do
        def real?
          true
        end

        def >=(_other)
          raise ArgumentError, 'no comparison'
        end
      end.new
      answers = answers_for.merge('mdq_intent__stock' => { 'type' => 'noul', 'noul' => hostile })
      result = nil
      expect { result = map(answers) }.not_to raise_error
      expect(result).to be_nil
    end
  end
end
