# frozen_string_literal: true

require 'rails_helper'

# The independent, model-free STRUCTURAL refusal validator. It makes no LLM call (so a denied
# Playground turn adds no provider latency and cannot 504) and accepts ONLY a short, single,
# prose-shaped candidate, rejecting blank / invalid-encoding / over-long / multi-line /
# code-or-JSON-shaped output. It enforces no attack-keyword blacklist and never raises.
RSpec.describe Marine::Circuit::BoundaryReplyValidator do
  let(:validator) { described_class.new }
  let(:candidate) { 'Sorry, I can only help with Textilindo products and services. How can I help you there?' }

  it 'makes no LLM call' do
    expect(Marine::Llm::BaseService).not_to receive(:new)
    validator.valid?(candidate: candidate, category: :unrelated)
  end

  it 'accepts a short, single, prose refusal' do
    expect(validator.valid?(candidate: candidate, category: :unrelated)).to be(true)
  end

  it 'accepts a one-sentence non-Latin refusal' do
    expect(validator.valid?(candidate: 'Maaf, saya hanya membantu soal Textilindo.', category: :unrelated, language: 'id')).to be(true)
  end

  describe 'Textilindo redirect contract' do
    it 'accepts a redirect regardless of brand casing' do
      expect(validator.valid?(candidate: 'Sorry, I can only help with TEXTILINDO products.', category: :unrelated)).to be(true)
    end

    it 'rejects an otherwise well-formed refusal that does NOT redirect to Textilindo' do
      expect(validator.valid?(candidate: 'Sorry, I cannot help with that request.', category: :unrelated)).to be(false)
    end
  end

  describe 'fail-closed' do
    it 'rejects a blank candidate' do
      expect(validator.valid?(candidate: '   ', category: :unrelated)).to be(false)
      expect(validator.valid?(candidate: nil, category: :unrelated)).to be(false)
    end

    it 'rejects invalid encoding' do
      expect(validator.valid?(candidate: "bad\xC3\x28 byte sequence here", category: :unrelated)).to be(false)
    end

    it 'rejects an over-long ramble' do
      long = "Sorry. #{'word ' * 200}"
      expect(validator.valid?(candidate: long, category: :unrelated)).to be(false)
    end

    it 'rejects a code-fenced candidate (model performed a task)' do
      expect(validator.valid?(candidate: "Here you go:\n```ruby\nputs 1\n```", category: :unrelated)).to be(false)
    end

    it 'rejects a whole-body JSON/object candidate' do
      expect(validator.valid?(candidate: '{"reply": "sorry"}', category: :unrelated)).to be(false)
      expect(validator.valid?(candidate: '[1, 2, 3]', category: :unrelated)).to be(false)
    end

    it 'rejects a multi-paragraph candidate' do
      multi = "Sorry, I cannot do that.\nHere is line two.\nAnd line three.\nAnd line four."
      expect(validator.valid?(candidate: multi, category: :unrelated)).to be(false)
    end

    it 'rejects a candidate with too many sentences' do
      many = 'No. No. No. No. No. No.'
      expect(validator.valid?(candidate: many, category: :unrelated)).to be(false)
    end
  end
end
