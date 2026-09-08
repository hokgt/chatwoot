# frozen_string_literal: true

require 'rails_helper'

# Phase 5 — contextual wording for approved-FAQ answers only. The service generates
# an untrusted candidate from the approved answer + latest request + Phase 2 history,
# applies Phase 4 greeting enforcement, then delivers it ONLY after a SEPARATE
# FactPreservationValidator call accepts the exact enforced candidate. Every
# generation/validation failure or uncertainty returns nil (non-delivery signal).
RSpec.describe Marine::Charge::GroundedWordingService do
  let(:service) { described_class.new(account: nil) }
  let(:approved) { 'Our office is at Jl. Mawar 1, Bandung, open 09:00 to 17:00.' }

  # The provider now enforces a bare { "reply": <string> } generation envelope and BaseService
  # returns its JSON text; stub_generation wraps the intended reply body in that envelope so specs
  # still express the reply the model produced while exercising the real envelope-extraction path.
  def reply_envelope(message)
    { reply: message }.to_json
  end

  def stub_generation(message:, success: true)
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat).and_return({ ok: success, message: reply_envelope(message), error: nil })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    llm
  end

  def stub_validator(accepted)
    validator = instance_double(Marine::Charge::FactPreservationValidator, valid?: accepted)
    allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)
    validator
  end

  it 'returns the candidate when generation succeeds and validation accepts' do
    stub_generation(message: 'Kantor kami di Jl. Mawar 1, Bandung, buka 09:00 sampai 17:00.')
    stub_validator(true)

    result = service.call(approved_answer: approved, customer_request: 'di mana kantor?')

    expect(result).to eq('Kantor kami di Jl. Mawar 1, Bandung, buka 09:00 sampai 17:00.')
  end

  it 'returns nil when validation rejects the candidate' do
    stub_generation(message: 'Kantor kami di Jl. Mawar 1 dan kami memberi diskon 50%.')
    stub_validator(false)

    expect(service.call(approved_answer: approved, customer_request: 'di mana kantor?')).to be_nil
  end

  it 'returns nil for a blank generation' do
    stub_generation(message: '')
    validator = stub_validator(true)

    expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
    expect(validator).not_to have_received(:valid?)
  end

  it 'returns nil when generation returns an LLM error' do
    stub_generation(message: nil, success: false)
    validator = stub_validator(true)

    expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
    expect(validator).not_to have_received(:valid?)
  end

  it 'returns nil when generation raises' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat).and_raise(StandardError, 'boom')
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    stub_validator(true)

    expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
  end

  it 'returns nil when the LLM is unconfigured' do
    allow(Marine::Llm::BaseService).to receive(:new).and_return(instance_double(Marine::Llm::BaseService, configured?: false))
    validator = stub_validator(true)

    expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
    expect(validator).not_to have_received(:valid?)
  end

  it 'validates the exact candidate after Phase 4 greeting enforcement on a follow-up turn' do
    stub_generation(message: 'Halo! Kantor kami di Jl. Mawar 1, Bandung.')
    validator = instance_double(Marine::Charge::FactPreservationValidator)
    captured = {}
    allow(validator).to receive(:valid?) do |args|
      captured.merge!(args)
      true
    end
    allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)

    result = service.call(approved_answer: approved, customer_request: 'di mana kantor?', opening: false)

    # the follow-up opening salutation is removed BEFORE validation and delivery
    expect(captured[:candidate]).to eq('Kantor kami di Jl. Mawar 1, Bandung.')
    expect(result).to eq('Kantor kami di Jl. Mawar 1, Bandung.')
  end

  it 'fails closed without validating when a follow-up reply is only an opening greeting' do
    stub_generation(message: 'Halo!')
    validator = stub_validator(true)

    expect(service.call(approved_answer: approved, customer_request: 'x', opening: false)).to be_nil
    expect(validator).not_to have_received(:valid?)
  end

  it 'normalizes a wrong-time opening greeting before validation on an opening turn' do
    stub_generation(message: 'Selamat sore, kantor kami di Jl. Mawar 1.')
    validator = instance_double(Marine::Charge::FactPreservationValidator)
    captured = {}
    allow(validator).to receive(:valid?) do |args|
      captured.merge!(args)
      true
    end
    allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)

    travel_to(Time.utc(2026, 7, 20, 2, 37)) do # 09:37 WIB -> pagi
      result = service.call(approved_answer: approved, customer_request: 'di mana kantor?', opening: true)
      expect(captured[:candidate]).to eq('Selamat pagi, kantor kami di Jl. Mawar 1.')
      expect(result).to eq('Selamat pagi, kantor kami di Jl. Mawar 1.')
    end
  end

  it 'grounds the generation prompt only on the approved answer, latest request, and history' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured[:system] = args[:system]
      captured[:messages] = args[:messages]
      { ok: true, message: reply_envelope('ok'), error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    stub_validator(true)

    history = [{ role: 'user', content: 'earlier question' }, { role: 'assistant', content: 'earlier answer' }]
    service.call(approved_answer: approved, customer_request: 'di mana kantor?', message_history: history, opening: true)

    expect(captured[:system]).to include(approved)
    # the generic wording instruction, not the RAG grounding prompt
    expect(captured[:system]).not_to include('Knowledge Base Context')
    expect(captured[:system]).not_to include('Guardrails')
    contents = captured[:messages].map { |m| m[:content] || m['content'] }
    expect(contents).to eq(['earlier question', 'earlier answer', 'di mana kantor?'])
    expect(contents.count('di mana kantor?')).to eq(1)
  end

  # Finding 2 — the reply body extracted from the generation envelope is untrusted, so the generic
  # output-shape gate still runs on it BEFORE greeting enforcement and validation: a NUL/control,
  # whole-fenced, or whole-JSON reply is rejected (nil, validator never called), while ordinary prose
  # that merely contains braces/punctuation is accepted and validated. (Non-String and invalid
  # encoding are now caught one layer earlier by envelope extraction — see 'generation envelope'.)
  describe 'output-shape gate (Finding 2)' do
    it 'returns nil without validating on NUL/unsafe control characters in the reply body' do
      stub_generation(message: "Kantor kami#{0.chr} di Jl. Mawar 1.")
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating a whole fenced reply body' do
      stub_generation(message: "```\nKantor kami di Jl. Mawar 1.\n```")
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating a whole JSON-object reply body' do
      stub_generation(message: '{"reply": "Kantor kami di Jl. Mawar 1."}')
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating a whole JSON-array reply body' do
      stub_generation(message: '["Kantor kami", "Jl. Mawar 1"]')
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'accepts and validates ordinary prose that merely contains braces and punctuation' do
      stub_generation(message: 'Biaya paket {khusus} adalah Rp10.000 — hubungi kami!')
      stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x'))
        .to eq('Biaya paket {khusus} adalah Rp10.000 — hubungi kami!')
    end
  end

  # Gate F structural stabilization — generation is requested as a provider-enforced
  # { "reply": <string> } envelope (REPLY_SCHEMA) parsed as an EXACT object with NO fence
  # stripping/extraction/repair. Anything that is not a bare { "reply": <string> } fails closed
  # to nil and the caller keeps its exact fallback; the semantic validator is never consulted.
  # The reply body itself stays a free contextual rephrase, so nothing here requires the approved
  # answer to appear verbatim.
  describe 'generation envelope' do
    def stub_raw_generation(raw)
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat).and_return({ ok: true, message: raw, error: nil })
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      llm
    end

    it 'requests provider-enforced structured output with the strict reply envelope schema' do
      captured = {}
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat) do |args|
        captured.merge!(args)
        { ok: true, message: reply_envelope('Kantor kami di Jl. Mawar 1.'), error: nil }
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      stub_validator(true)

      service.call(approved_answer: approved, customer_request: 'x')

      schema = captured[:schema]
      expect(schema[:strict]).to be(true)
      expect(schema.dig(:schema, :type)).to eq('object')
      expect(schema.dig(:schema, :additionalProperties)).to be(false)
      expect(schema.dig(:schema, :required)).to eq(%w[reply])
      expect(schema.dig(:schema, :properties, 'reply')).to eq({ type: 'string' })
    end

    it 'extracts and validates the reply body from a well-formed envelope' do
      stub_raw_generation(reply_envelope('Kantor kami di Jl. Mawar 1, Bandung.'))
      stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x'))
        .to eq('Kantor kami di Jl. Mawar 1, Bandung.')
    end

    it 'returns nil without validating when the envelope reply is not a string' do
      stub_raw_generation({ reply: { nested: 'x' } }.to_json)
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating when the envelope is missing the reply key' do
      stub_raw_generation({ note: 'x' }.to_json)
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating when the envelope carries an extra key' do
      stub_raw_generation({ reply: 'Kantor kami di Jl. Mawar 1.', note: 'x' }.to_json)
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating on a duplicated reply key (no silent last-value win)' do
      stub_raw_generation('{"reply": "first", "reply": "second"}')
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating on malformed envelope JSON (no repair)' do
      stub_raw_generation('{"reply": "Kantor kami di Jl. Mawar 1.",')
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating on a fenced/passed-through envelope (no fence stripping)' do
      stub_raw_generation("```json\n#{reply_envelope('Kantor kami di Jl. Mawar 1.')}\n```")
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating on a wrong top-level envelope type' do
      stub_raw_generation('["reply"]')
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating on an invalid-encoding envelope' do
      stub_raw_generation((+"\xff\xfe").force_encoding('UTF-8'))
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end
  end

  # Finding 3 — a generation Timeout::Error is a fail-closed non-delivery signal: return nil
  # and never reach the validator (BaseService timeout/retry/config is unchanged).
  it 'returns nil without validating when generation times out (Finding 3)' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat).and_raise(Timeout::Error)
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    validator = stub_validator(true)

    expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
    expect(validator).not_to have_received(:valid?)
  end

  # Gate F — generation is requested at temperature 0.0 as a variance-reducing control (greedy
  # decoding minimizes sampling variance so the rephrase drifts less run-to-run); temperature 0.0 is
  # NOT a determinism guarantee. It never relaxes acceptance: the candidate stays fully untrusted and
  # still passes the shape gate, greeting enforcement, and the separate semantic validator unchanged.
  it 'requests the generation at variance-reducing temperature 0.0' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured.merge!(args)
      { ok: true, message: reply_envelope('ok'), error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    stub_validator(true)

    service.call(approved_answer: approved, customer_request: 'di mana kantor?')

    expect(captured[:temperature]).to eq(0.0)
  end
end
