# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::JsonResponseParser do
  subject(:parser) { described_class.new(default: { 'ok' => false }) }

  it 'parses a plain JSON object string' do
    expect(parser.parse('{"a":1,"b":"two"}')).to eq({ 'a' => 1, 'b' => 'two' })
  end

  it 'returns hashes and arrays untouched' do
    expect(parser.parse({ a: 1 })).to eq({ a: 1 })
    expect(parser.parse([1, 2])).to eq([1, 2])
  end

  it 'strips markdown code fences' do
    text = "```json\n{\"a\":1}\n```"
    expect(parser.parse(text)).to eq({ 'a' => 1 })
  end

  it 'extracts JSON embedded in surrounding prose' do
    text = 'Sure, here you go: {"a": 1} hope that helps!'
    expect(parser.parse(text)).to eq({ 'a' => 1 })
  end

  it 'falls back to the default on unparseable input' do
    expect(parser.parse('not json at all')).to eq({ 'ok' => false })
  end

  it 'falls back to the default on blank input' do
    expect(parser.parse('')).to eq({ 'ok' => false })
    expect(parser.parse(nil)).to eq({ 'ok' => false })
  end
end
