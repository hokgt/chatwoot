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
