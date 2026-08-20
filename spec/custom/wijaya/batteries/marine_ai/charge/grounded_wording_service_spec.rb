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

  def stub_generation(message:, success: true)
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat).and_return({ ok: success, message: message, error: nil })
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
      { ok: true, message: 'ok', error: nil }
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

  # Finding 2 — the generation is untrusted, so a generic output-shape gate runs BEFORE
  # greeting enforcement and validation: non-String, invalid-encoding, NUL/control, a whole
  # fenced block, and a whole JSON object/array are rejected (nil, validator never called),
  # while ordinary prose that merely contains braces/punctuation is accepted and validated.
  describe 'output-shape gate (Finding 2)' do
    it 'returns nil without validating when generation is a non-String' do
      stub_generation(message: { reply: 'Kantor kami di Jl. Mawar 1.' })
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating on invalid string encoding' do
      stub_generation(message: (+"\xff\xfe").force_encoding('UTF-8'))
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating on NUL/unsafe control characters' do
      stub_generation(message: "Kantor kami#{0.chr} di Jl. Mawar 1.")
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating a whole fenced block' do
      stub_generation(message: "```\nKantor kami di Jl. Mawar 1.\n```")
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating a whole JSON object' do
      stub_generation(message: '{"reply": "Kantor kami di Jl. Mawar 1."}')
      validator = stub_validator(true)

      expect(service.call(approved_answer: approved, customer_request: 'x')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil without validating a whole JSON array' do
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
end
