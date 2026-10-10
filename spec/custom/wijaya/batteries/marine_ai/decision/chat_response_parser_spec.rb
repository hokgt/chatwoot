# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 3 — the strict chat/completions response parser. These examples pin that
# a Hash payload passes through, and a String payload must be EXACTLY one JSON object: no
# fences, no prose, no trailing tokens, within bounds, valid encoding, and with NO duplicate
# JSON keys at any depth (rejected by allow_duplicate_key: false, not last-key-wins).
RSpec.describe Marine::Decision::ChatResponseParser do
  it 'returns a Hash payload unchanged (structured RubyLLM output)' do
    payload = { 'schema_version' => 'marine_decision_v1' }
    expect(described_class.parse(payload)).to equal(payload)
  end

  it 'parses exactly one JSON object from a String, tolerating surrounding whitespace' do
    expect(described_class.parse(%(  {"a":1}  ))).to eq('a' => 1)
  end

  it 'rejects code fences, leading prose, and trailing tokens' do
    expect(described_class.parse("```json\n{\"a\":1}\n```")).to be_nil
    expect(described_class.parse('here you go: {"a":1}')).to be_nil
    expect(described_class.parse('{"a":1} trailing')).to be_nil
  end

  it 'rejects non-object JSON, blanks, and non-string/non-hash payloads' do
    expect(described_class.parse('[1,2,3]')).to be_nil
    expect(described_class.parse('"just a string"')).to be_nil
    expect(described_class.parse('   ')).to be_nil
    expect(described_class.parse(nil)).to be_nil
    expect(described_class.parse(42)).to be_nil
  end

  it 'rejects an oversized String before parsing' do
    huge = "{\"a\":\"#{'x' * described_class::MAX_BYTES}\"}"
    expect(described_class.parse(huge)).to be_nil
  end

  it 'rejects duplicate JSON keys at the top level and when nested' do
    expect(described_class.parse('{"a":1,"a":2}')).to be_nil
    expect(described_class.parse('{"a":1,"b":{"c":1,"c":2}}')).to be_nil
  end

  it 'rejects invalid encoding' do
    expect(described_class.parse("{\"a\":\"\xff\"}".b.force_encoding('UTF-8'))).to be_nil
  end
end
