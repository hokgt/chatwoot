# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 3 — the mode-specific protocol request builder. These examples pin the
# EXACT request bodies for both protocols: a closed chat schema over the Stage 1 candidate
# keys with scenario text carried only as DATA, and a Decisions questions/state body with
# ONE scenario choice question + one NOUL question per candidate intent — never a free-text
# extraction question. All scenario/product strings are SYNTHETIC.
RSpec.describe Marine::Decision::RequestBuilder do
  schema_mod = Marine::Decision::Schema

  def scenarios
    [
      { 'key' => 'stock_check', 'description' => 'Availability question', 'instruction' => 'Check stock' },
      { 'key' => 'catalog_browse', 'description' => 'Browsing', 'instruction' => 'Show catalog' }
    ]
  end

  let(:input) do
    Marine::Decision::InputContract.build(
      message: 'Do you have the vase in stock?',
      context: [{ 'role' => 'user', 'content' => 'hi' }],
      state: { 'current_intent' => 'stock' },
      scenarios: scenarios,
      classification_intents: %w[price unsupported]
    )
  end

  describe 'chat_completions' do
    subject(:request) { described_class.build(mode: 'chat_completions', input: input) }

    it 'builds a static system prompt, one JSON-envelope user message, temperature 0' do
      expect(request[:system]).to eq(described_class::SYSTEM_PROMPT)
      expect(request[:temperature]).to eq(0)
      expect(request[:messages].length).to eq(1)
      expect(request[:messages].first[:role]).to eq('user')

      envelope = JSON.parse(request[:messages].first[:content])
      expect(envelope['message']).to eq('Do you have the vase in stock?')
      expect(envelope['context']).to eq([{ 'role' => 'user', 'content' => 'hi' }])
      expect(envelope['state']).to eq('current_intent' => 'stock')
      expect(envelope['scenarios'].map { |s| s['key'] }).to eq(%w[stock_check catalog_browse])
      # Scenario envelope carries identity/context only — NO capabilities.
      expect(envelope['scenarios']).to all(satisfy { |s| !s.key?('capabilities') })
    end

    it 'emits a closed schema over the exact Stage 1 keys, with a scenario-key enum and the injected classification enum' do
      schema = request[:schema]
      expect(schema['additionalProperties']).to be(false)
      expect(schema['required']).to eq(%w[schema_version scenario_candidate intents slot_operations customer_language confidence])
      expect(schema['properties']['schema_version']['enum']).to eq([schema_mod::SCHEMA_VERSION])
      expect(schema['properties']['scenario_candidate']['properties']['key']['enum']).to eq(%w[stock_check catalog_browse] + [nil])
      expect(schema['properties']['intents']['items']['enum']).to eq(%w[price unsupported])
      expect(schema['properties']['intents']['maxItems']).to eq(schema_mod::MAX_INTENTS)
      expect(schema['properties']['scenario_candidate']['additionalProperties']).to be(false)
      expect(schema).not_to have_key('reason')
      expect(schema['properties']).not_to have_key('reason')
    end

    it 'constrains slot operations per-slot as far as JSON Schema can express' do
      variants = request[:schema]['properties']['slot_operations']['items']['oneOf']
      product = variants.find { |v| v.dig('properties', 'slot', 'enum') == %w[product] }
      expect(product['properties']['value']['properties']['candidate_type']['enum']).to eq(%w[display_name family_code])
    end
  end

  describe 'openrouter_decisions' do
    subject(:request) { described_class.build(mode: 'openrouter_decisions', input: input) }

    it 'builds one scenario choice question keyed by the supplied scenario keys' do
      scenario_q = request[:questions]['scenario_candidate']
      expect(scenario_q['type']).to eq('choice')
      expect(scenario_q['criteria'].keys).to eq(%w[stock_check catalog_browse])
      expect(scenario_q['criteria']['stock_check']).to eq('Availability question')
    end

    it 'uses the official `instructions` key (not `question`) for the choice question' do
      scenario_q = request[:questions]['scenario_candidate']
      expect(scenario_q).to have_key('instructions')
      expect(scenario_q['instructions']).to be_a(String)
      expect(scenario_q['instructions']).not_to be_empty
      expect(scenario_q).not_to have_key('question')
    end

    it 'builds one NOUL question per injected classification intent with exact false/true criteria' do
      keys = request[:questions].keys
      expect(keys).to eq(%w[scenario_candidate] + %w[price unsupported].map { |i| "mdq_intent__#{i}" })
      noul = request[:questions]['mdq_intent__price']
      expect(noul['type']).to eq('noul')
      expect(noul['criteria'].keys).to eq(%w[false true])
    end

    it 'uses the official `instructions` key (not `question`) for every NOUL question' do
      nouls = request[:questions].except('scenario_candidate').values
      expect(nouls).not_to be_empty
      nouls.each do |noul|
        expect(noul).to have_key('instructions')
        expect(noul['instructions']).to be_a(String)
        expect(noul['instructions']).not_to be_empty
        expect(noul).not_to have_key('question')
      end
    end

    it 'gives the mutually-exclusive product intents discriminating criteria (not the generic wording)' do
      product_input = Marine::Decision::InputContract.build(
        message: 'Produk apa saja yang tersedia', context: [], state: {},
        scenarios: [{ 'key' => 'product_scenario', 'description' => 'catalog', 'instruction' => 'read' }],
        classification_intents: %w[product_listing product_information price unsupported]
      )
      questions = described_class.build(mode: 'openrouter_decisions', input: product_input)[:questions]
      listing = questions['mdq_intent__product_listing']
      information = questions['mdq_intent__product_information']

      # Each member's criteria name the OTHER member as out-of-scope, so an overlapping turn no
      # longer scores both high; generic intents keep the generic wording.
      expect(listing['criteria']['true']).to include('WITHOUT requesting any description')
      expect(listing['criteria']['false']).to include('product_information')
      expect(information['criteria']['true']).to include('EXPLICITLY asks for a description')
      expect(information['criteria']['false']).to include('product_listing')
    end

    it 'gives price and price_range mutually-exclusive discriminating criteria (specific item vs family-wide span)' do
      product_input = Marine::Decision::InputContract.build(
        message: 'Yang itu harganya berapa', context: [], state: {},
        scenarios: [{ 'key' => 'product_scenario', 'description' => 'catalog', 'instruction' => 'read' }],
        classification_intents: %w[price price_range stock unsupported]
      )
      questions = described_class.build(mode: 'openrouter_decisions', input: product_input)[:questions]
      price = questions['mdq_intent__price']
      price_range = questions['mdq_intent__price_range']

      # price = a SPECIFIC item/variant; price_range = a general family-wide span with NO specific item.
      # Each names the other as out-of-scope so an exact-item turn no longer scores both high.
      expect(price['criteria']['true']).to match(/specific/i)
      expect(price['criteria']['false']).to include('price_range')
      expect(price_range['criteria']['true']).to match(/\bno\b.*specific|without.*specific|whole.*family|family-wide/i)
      expect(price_range['criteria']['false']).to include('price')
      # generic intents keep the generic wording.
      expect(questions['mdq_intent__stock']['criteria']['true'])
        .to eq("The 'stock' intent IS explicitly present in the latest customer turn or context.")
    end

    it 'covers broad catalog/list product-information requests without requiring a specific or named product' do
      broad_input = Marine::Decision::InputContract.build(
        message: 'Jelaskan produk kain yang tersedia', context: [], state: {},
        scenarios: [{ 'key' => 'product_scenario', 'description' => 'catalog', 'instruction' => 'read' }],
        classification_intents: %w[product_listing product_information]
      )
      information = described_class.build(mode: 'openrouter_decisions', input: broad_input)[:questions]['mdq_intent__product_information']
      true_criterion = information['criteria']['true']

      # The description/explanation of the products in a requested catalog / list qualifies as
      # product_information — a named product is one case, not a precondition.
      expect(true_criterion).to match(/catalog|list/i)
      expect(true_criterion).to include('named product OR')
      # And it must NOT bias the provider back toward demanding a pre-identified/specific product.
      expect(true_criterion).not_to match(/specific products?/i)
    end

    it 'never asks Jev to extract free text (no non-choice/noul question types)' do
      types = request[:questions].values.map { |q| q['type'] }.uniq
      expect(types).to match_array(%w[choice noul])
    end

    it 'puts only the bounded data envelope in state' do
      expect(request[:state].keys).to eq(%w[message context state scenarios])
      expect(request[:state]['message']).to eq('Do you have the vase in stock?')
    end

    it 'builds exactly one choice criterion for a single supplied scenario (no invented fallback key)' do
      single = Marine::Decision::InputContract.build(
        message: 'Do you have the vase in stock?', context: [], state: {},
        scenarios: [{ 'key' => 'stock_check', 'description' => 'Availability question', 'instruction' => 'Check' }],
        classification_intents: %w[price unsupported]
      )
      scenario_q = described_class.build(mode: 'openrouter_decisions', input: single)[:questions]['scenario_candidate']
      expect(scenario_q['type']).to eq('choice')
      expect(scenario_q['criteria'].keys).to eq(%w[stock_check])
      expect(scenario_q['criteria']['stock_check']).to eq('Availability question')
    end
  end

  describe 'price vs price_range classification contract (SYSTEM_PROMPT, chat mode)' do
    # chat_completions is the live default api_mode; the model emits the intents array directly
    # against the enum, so SYSTEM_PROMPT is the only lever that can keep a specific-item price turn
    # from also proposing the family-wide price_range.
    it 'collapses subsuming price/price_range alternatives to one most-specific member' do
      prompt = described_class::SYSTEM_PROMPT
      # price and price_range are refinements of the SAME pricing request → pick only the most-specific one.
      expect(prompt).to match(/price_range/)
      expect(prompt).to match(/most-specific/i)
      expect(prompt).to match(/refinement|subsuming|same request|same.*pricing/i)
      # price = a specific item; price_range = a general family-wide span with no specific item.
      expect(prompt).to match(/specific/i)
    end

    it 'does NOT force genuinely distinct independent intents to collapse to a single primary' do
      prompt = described_class::SYSTEM_PROMPT
      # The collapse rule is scoped to refinements of one request; distinct co-present requests
      # (e.g. price AND stock) must each remain nominable so the whole-plan policy can fall back
      # to the legacy composite path rather than silently dropping one intent.
      expect(prompt).to match(/distinct/i)
      expect(prompt).to match(/independent/i)
      expect(prompt).not_to match(/nominate the SINGLE most-specific primary intent rather than overlapping ones/)
    end
  end

  describe 'mode allowlist (defense in depth)' do
    it 'raises a fixed local Invalid for any unknown mode, carrying no input' do
      expect { described_class.build(mode: 'bogus_mode', input: input) }.to raise_error(described_class::Invalid)
      begin
        described_class.build(mode: 'bogus_mode', input: input)
      rescue described_class::Invalid => e
        expect(e.message).not_to include('bogus_mode')
      end
    end
  end
end
