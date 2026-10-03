# frozen_string_literal: true

require 'rails_helper'

# Langkah 3 (Evidence Packet -> Model 2 SHADOW) — the generator adapter over the EXISTING Response
# Generator config. It asks for a strict { "reply": <string> } envelope at temperature 0 and parses
# it EXACTLY, returning the reply String or nil. Any unconfigured/error/malformed/oversize/blank/
# fenced/wrong-envelope/duplicate-key outcome fails closed to nil so the presenter falls back.
RSpec.describe Marine::Backend::EvidenceReplyGenerator do
  subject(:generator) { described_class.new }

  let(:system) { 'You are Marine. Evidence Packet: {"evidence_version":"marine_evidence_v1"}' }
  let(:messages) { [{ role: 'user', content: 'Berapa harga BD-4?' }] }

  def stub_llm(message:, success: true, configured: true)
    llm = instance_double(Marine::Llm::BaseService, configured?: configured)
    allow(llm).to receive(:chat).and_return({ ok: success, message: message, error: nil })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    llm
  end

  def envelope(reply)
    { reply: reply }.to_json
  end

  it 'returns the reply body from a clean one-field envelope' do
    stub_llm(message: envelope('Halo! Harga BD-4 adalah Rp 12.500 per yard.'))
    expect(generator.call(system: system, messages: messages)).to eq('Halo! Harga BD-4 adalah Rp 12.500 per yard.')
  end

  it 'requests the Response Generator at temperature 0 with the reply schema' do
    llm = stub_llm(message: envelope('ok'))
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured.merge!(args)
      { ok: true, message: envelope('ok'), error: nil }
    end

    generator.call(system: system, messages: messages)

    expect(captured[:temperature]).to eq(0.0)
    expect(captured[:schema]).to eq(described_class::REPLY_SCHEMA)
    expect(captured[:system]).to eq(system)
    expect(captured[:messages]).to eq(messages)
  end

  it 'fails closed when the Response Generator is not configured (no provider call)' do
    llm = stub_llm(message: envelope('ok'), configured: false)
    expect(llm).not_to receive(:chat)
    expect(generator.call(system: system, messages: messages)).to be_nil
  end

  it 'fails closed on a provider error result' do
    stub_llm(message: nil, success: false)
    expect(generator.call(system: system, messages: messages)).to be_nil
  end

  it 'fails closed on a raised provider exception' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat).and_raise(StandardError, 'boom')
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    expect(generator.call(system: system, messages: messages)).to be_nil
  end

  it 'fails closed on a blank system prompt or empty messages without touching the provider' do
    expect(Marine::Llm::BaseService).not_to receive(:new)
    expect(generator.call(system: '   ', messages: messages)).to be_nil
    expect(generator.call(system: system, messages: [])).to be_nil
    expect(generator.call(system: system, messages: 'nope')).to be_nil
  end

  it 'fails closed on a fenced / non-envelope / wrong-key / non-string / blank reply' do
    [
      '```json\n{"reply":"hi"}\n```',
      'just some prose',
      { answer: 'hi' }.to_json,
      { reply: 123 }.to_json,
      { reply: '   ' }.to_json,
      { reply: 'hi', extra: 'x' }.to_json
    ].each do |message|
      stub_llm(message: message)
      expect(generator.call(system: system, messages: messages)).to be_nil
    end
  end

  it 'fails closed on an ambiguous duplicate reply key' do
    stub_llm(message: '{"reply":"a","reply":"b"}')
    expect(generator.call(system: system, messages: messages)).to be_nil
  end

  it 'fails closed on an oversized reply' do
    stub_llm(message: envelope('x' * (described_class::MAX_REPLY_BYTES + 1)))
    expect(generator.call(system: system, messages: messages)).to be_nil
  end
end
