# frozen_string_literal: true

require 'rails_helper'

# Phase 5 — the untrusted contextual candidate is only delivered when a SEPARATE
# semantic validation call proves it preserves the approved answer's facts. The
# validator requests strict machine-readable JSON and fails closed on anything that
# is not a complete, exact, all-true verdict.
RSpec.describe Marine::Charge::FactPreservationValidator do
  let(:validator) { described_class.new }
  let(:approved) { 'Our office is at Jl. Mawar 1, Bandung, open 09:00 to 17:00.' }
  let(:candidate) { 'Sure! Our office is at Jl. Mawar 1, Bandung, open 09:00 to 17:00.' }

  def stub_llm(message:, success: true)
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat).and_return({ ok: success, message: message, error: nil })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    llm
  end

  def verdict(all: true, added: true, contradiction: true, equivalent: true, certain: true)
    {
      all_facts_preserved: all,
      no_unsupported_facts_added: added,
      no_contradiction: contradiction,
      meaning_equivalent: equivalent,
      certain: certain
    }.to_json
  end

  it 'accepts a complete all-true JSON verdict' do
    stub_llm(message: verdict)
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(true)
  end

  it 'passes the approved answer and the exact candidate to the LLM' do
    llm = stub_llm(message: verdict)
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured[:messages] = args[:messages]
      { ok: true, message: verdict, error: nil }
    end

    validator.valid?(approved_answer: approved, candidate: candidate)

    prompt = captured[:messages].map { |m| m[:content] }.join("\n")
    expect(prompt).to include(approved).and include(candidate)
  end

  it 'rejects when a material fact is omitted (all_facts_preserved false)' do
    stub_llm(message: verdict(all: false))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects when an unsupported fact is added (no_unsupported_facts_added false)' do
    stub_llm(message: verdict(added: false))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects a contradiction (no_contradiction false)' do
    stub_llm(message: verdict(contradiction: false))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects when meaning is not equivalent/entailed (meaning_equivalent false)' do
    stub_llm(message: verdict(equivalent: false))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects an uncertain verdict (certain false)' do
    stub_llm(message: verdict(certain: false))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects a blank verdict' do
    stub_llm(message: '')
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects a fenced JSON verdict (no repair)' do
    stub_llm(message: "```json\n#{verdict}\n```")
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects a verdict wrapped in extra prose (no extraction)' do
    stub_llm(message: "Here is my verdict: #{verdict}")
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects malformed JSON' do
    stub_llm(message: '{ "all_facts_preserved": true, ')
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects a JSON array (wrong top-level type)' do
    stub_llm(message: '[true, true, true, true, true]')
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects a bare boolean (wrong top-level type)' do
    stub_llm(message: 'true')
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects a verdict missing a required key' do
    missing = { all_facts_preserved: true, no_unsupported_facts_added: true, no_contradiction: true, meaning_equivalent: true }
    stub_llm(message: missing.to_json)
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects a verdict with an extra key' do
    extra = JSON.parse(verdict).merge('extra' => true)
    stub_llm(message: extra.to_json)
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects non-boolean verdict values' do
    non_boolean = JSON.parse(verdict).merge('all_facts_preserved' => 'yes')
    stub_llm(message: non_boolean.to_json)
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects when the LLM returns an error' do
    stub_llm(message: nil, success: false)
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects when the LLM call raises' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat).and_raise(StandardError, 'boom')
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects when the LLM is unconfigured' do
    allow(Marine::Llm::BaseService).to receive(:new).and_return(instance_double(Marine::Llm::BaseService, configured?: false))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  # Finding 4 — Ruby's JSON.parse silently keeps the last value for a duplicated key, so an
  # ambiguous verdict that repeats a required key (false then true) would otherwise pass. The
  # strict object class rejects the duplicate as malformed instead of collapsing to last-wins.
  it 'rejects a duplicated required key with conflicting values (no silent last-value win)' do
    dup = '{"all_facts_preserved": false, "all_facts_preserved": true, ' \
          '"no_unsupported_facts_added": true, "no_contradiction": true, ' \
          '"meaning_equivalent": true, "certain": true}'
    stub_llm(message: dup)
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  # A duplicate key is malformed regardless of whether the repeated values agree: the
  # parser rejects it before value inspection, so an all-true verdict that simply repeats
  # a required key is still refused rather than collapsed to a single accepted field.
  it 'rejects a duplicated required key even with matching values (still malformed)' do
    dup = '{"all_facts_preserved": true, "all_facts_preserved": true, ' \
          '"no_unsupported_facts_added": true, "no_contradiction": true, ' \
          '"meaning_equivalent": true, "certain": true}'
    stub_llm(message: dup)
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  # Finding 3 — a validation Timeout::Error is a fail-closed rejection: return false (never
  # deliver the candidate). BaseService timeout/retry/config is unchanged.
  it 'rejects when the LLM call times out' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat).and_raise(Timeout::Error)
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end
end
