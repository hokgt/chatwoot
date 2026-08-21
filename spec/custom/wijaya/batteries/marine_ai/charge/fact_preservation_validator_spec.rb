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

  # The five-field verdict object as JSON text (what the provider carries inside the envelope).
  def inner_verdict(all: true, added: true, contradiction: true, equivalent: true, certain: true)
    {
      all_facts_preserved: all,
      no_unsupported_facts_added: added,
      no_contradiction: contradiction,
      meaning_equivalent: equivalent,
      certain: certain
    }.to_json
  end

  # What BaseService returns on the schema path: RubyLLM parsed the { "verdict": "<json>" } envelope
  # to a Hash and BaseService reserialized it, so the message is the envelope JSON text with the
  # verdict object carried verbatim as a string value.
  def envelope(inner)
    { verdict: inner }.to_json
  end

  def verdict(**)
    envelope(inner_verdict(**))
  end

  # Drives the REAL Marine::Llm::BaseService (only the low-level RubyLLM chat is stubbed) so the
  # schema path runs for real — RubyLLM's eager JSON parse of the envelope plus BaseService's
  # reserialization — unlike stub_llm, which replaces BaseService#chat wholesale.
  def stub_real_schema_path(provider_envelope_json)
    allow(Marine::Llm::Config).to receive(:configured?).and_return(true)
    # RubyLLM JSON.parse's the envelope object before handing back the message.
    response = instance_double(RubyLLM::Message, content: JSON.parse(provider_envelope_json))
    chat = instance_double(RubyLLM::Chat)
    allow(chat).to receive_messages(with_instructions: nil, with_temperature: nil, with_schema: nil, add_message: nil, ask: response)
    allow_any_instance_of(Marine::Llm::BaseService).to receive(:build_chat).and_return(chat)
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
    stub_llm(message: envelope(missing.to_json))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects a verdict with an extra key' do
    extra = JSON.parse(inner_verdict).merge('extra' => true)
    stub_llm(message: envelope(extra.to_json))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects non-boolean verdict values' do
    non_boolean = JSON.parse(inner_verdict).merge('all_facts_preserved' => 'yes')
    stub_llm(message: envelope(non_boolean.to_json))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects an envelope whose verdict field is a JSON object rather than a string' do
    stub_llm(message: { verdict: JSON.parse(inner_verdict) }.to_json)
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects a bare five-field verdict not wrapped in the envelope' do
    stub_llm(message: inner_verdict)
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  it 'rejects an envelope carrying an extra top-level key' do
    stub_llm(message: { verdict: inner_verdict, note: 'x' }.to_json)
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
  # duplicate lives inside the verdict string; accepted?'s allow_duplicate_key: false rejects it
  # as malformed instead of collapsing to last-wins.
  it 'rejects a duplicated required key with conflicting values (no silent last-value win)' do
    dup = '{"all_facts_preserved": false, "all_facts_preserved": true, ' \
          '"no_unsupported_facts_added": true, "no_contradiction": true, ' \
          '"meaning_equivalent": true, "certain": true}'
    stub_llm(message: envelope(dup))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  # A duplicate key is malformed regardless of whether the repeated values agree: the
  # parser rejects it before value inspection, so an all-true verdict that simply repeats
  # a required key is still refused rather than collapsed to a single accepted field.
  it 'rejects a duplicated required key even with matching values (still malformed)' do
    dup = '{"all_facts_preserved": true, "all_facts_preserved": true, ' \
          '"no_unsupported_facts_added": true, "no_contradiction": true, ' \
          '"meaning_equivalent": true, "certain": true}'
    stub_llm(message: envelope(dup))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end

  # Gate F schema-path regression — the reviewer finding: RubyLLM eagerly JSON.parse's a structured
  # reply into a Hash (silently deduplicating keys) before BaseService reserializes it, which would
  # let a duplicate-key verdict slip past accepted? on the schema path. These two examples exercise
  # the ACTUAL schema path (real BaseService reserialization + real accepted?), not a stubbed
  # BaseService#chat, proving the guarantee holds where it is actually enforced.
  it 'accepts an all-true verdict through the real schema path (RubyLLM parse + reserialization)' do
    stub_real_schema_path(envelope(inner_verdict))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(true)
  end

  it 'rejects duplicate keys carried through the real schema path (survives RubyLLM dedup)' do
    dup = '{"all_facts_preserved": false, "all_facts_preserved": true, ' \
          '"no_unsupported_facts_added": true, "no_contradiction": true, ' \
          '"meaning_equivalent": true, "certain": true}'
    envelope_json = envelope(dup)
    # RubyLLM parses only the envelope; the duplicate keys live inside the verdict string it never
    # descends into, so they reach accepted? verbatim rather than being collapsed to last-wins.
    expect(JSON.parse(envelope_json)['verdict']).to eq(dup)
    stub_real_schema_path(envelope_json)
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

  # Gate F — the verdict is a safety-critical decision, so it is requested at temperature 0.0 as a
  # variance-reducing control (greedy decoding minimizes sampling variance so the judgement drifts
  # less run-to-run); temperature 0.0 is NOT a determinism guarantee. It does not relax acceptance:
  # the fail-closed rules above are unchanged; it only reduces the sampling variance that made an
  # otherwise-equivalent candidate pass once and fail on a rerun.
  it 'requests the verdict at variance-reducing temperature 0.0' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured.merge!(args)
      { ok: true, message: verdict, error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)

    validator.valid?(approved_answer: approved, candidate: candidate)

    expect(captured[:temperature]).to eq(0.0)
  end

  # Gate F root cause — the live failure was a verdict that was NOT a JSON object parseable by
  # strict JSON.parse (fenced/prose). The structural fix is asking the provider to enforce a bare
  # { "verdict": "<json>" } envelope via VERDICT_SCHEMA — a single string field so RubyLLM's eager
  # parse cannot deduplicate the verdict's keys. This asserts the request carries that strict
  # schema; acceptance itself is still decided by accepted? (proven by the fail-closed cases above).
  it 'requests provider-enforced structured output with the strict verdict envelope schema' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured.merge!(args)
      { ok: true, message: verdict, error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)

    validator.valid?(approved_answer: approved, candidate: candidate)

    schema = captured[:schema]
    expect(schema[:strict]).to be(true)
    expect(schema.dig(:schema, :type)).to eq('object')
    expect(schema.dig(:schema, :additionalProperties)).to be(false)
    expect(schema.dig(:schema, :required)).to eq(%w[verdict])
    expect(schema.dig(:schema, :properties).keys.map(&:to_s)).to eq(%w[verdict])
    expect(schema.dig(:schema, :properties, 'verdict')).to eq({ type: 'string' })
  end

  # Generation and semantic validation stay separate: even when the provider enforces the schema
  # and returns a well-formed but NOT-all-true verdict, the candidate is rejected. Structured
  # output guarantees the shape, never the answer.
  it 'still rejects a well-formed schema-shaped verdict that is not all-true' do
    stub_llm(message: verdict(certain: false))
    expect(validator.valid?(approved_answer: approved, candidate: candidate)).to be(false)
  end
end
