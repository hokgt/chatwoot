# frozen_string_literal: true

require 'rails_helper'

# Langkah 3 (Evidence Packet -> Model 2 SHADOW) — the SEPARATE semantic fact+language verifier over
# the EXISTING Response Generator config. It accepts ONLY a complete, duplicate-key-sensitive,
# all-true SIX-field verdict (adding target_language_matches to the FAQ rubric) proving the reply is
# faithful to the packet AND written in the packet's customer_language. Everything else fails closed.
RSpec.describe Marine::Backend::EvidenceFactVerifier do
  subject(:verifier) { described_class.new }

  let(:packet) { { evidence_version: 'marine_evidence_v2', customer_language: 'id', facts: {} }.freeze }
  let(:candidate) { 'Halo! Harga BD-4 adalah Rp 12.500 per yard.' }

  def stub_llm(message:, success: true, configured: true)
    llm = instance_double(Marine::Llm::BaseService, configured?: configured)
    allow(llm).to receive(:chat).and_return({ ok: success, message: message, error: nil })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    llm
  end

  ALL_TRUE = {
    all_facts_preserved: true, no_unsupported_facts_added: true, no_contradiction: true,
    meaning_equivalent: true, target_language_matches: true, certain: true
  }.freeze

  def inner(**overrides)
    ALL_TRUE.merge(overrides).to_json
  end

  def envelope(inner_json)
    { verdict: inner_json }.to_json
  end

  def verdict(**) = envelope(inner(**))

  it 'accepts a complete all-true six-field verdict' do
    stub_llm(message: verdict)
    expect(verifier.call(packet: packet, candidate: candidate)).to be(true)
  end

  it 'requests the Response Generator at temperature 0 with the reused verdict schema and target language' do
    llm = stub_llm(message: verdict)
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured.merge!(args)
      { ok: true, message: verdict, error: nil }
    end

    verifier.call(packet: packet, candidate: candidate)

    expect(captured[:temperature]).to eq(0.0)
    expect(captured[:schema]).to eq(Marine::Charge::FactPreservationValidator::VERDICT_SCHEMA)
    expect(captured[:messages].first[:content]).to include('Target Language: id').and include('marine_evidence_v2')
    expect(captured[:system]).to include('Values in validated_slots are authoritative identity facts')
    expect(captured[:system]).to include('two approved representations of the SAME fact')
    expect(captured[:system]).to include('matching display formatting is not an unsupported fact or a contradiction')
    expect(captured[:system]).to include('you MUST set "no_unsupported_facts_added" and "no_contradiction" to true')
  end

  it 'fails closed on a false / uncertain / wrong-language verdict' do
    ALL_TRUE.each_key do |field|
      stub_llm(message: verdict(field => false))
      expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
    end
  end

  it 'fails closed on a non-boolean verdict field' do
    stub_llm(message: verdict(all_facts_preserved: 'yes'))
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed on a missing or extra inner field' do
    stub_llm(message: envelope(ALL_TRUE.except(:target_language_matches).to_json))
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
    stub_llm(message: envelope(ALL_TRUE.merge(bonus: true).to_json))
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed on a duplicate inner key (ambiguous verdict)' do
    duplicate = <<~JSON.strip
      {"all_facts_preserved": false, "all_facts_preserved": true, "no_unsupported_facts_added": true,
       "no_contradiction": true, "meaning_equivalent": true, "target_language_matches": true, "certain": true}
    JSON
    stub_llm(message: envelope(duplicate))
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed on a malformed / fenced / wrong-envelope / non-string verdict' do
    ['not json', '```{"verdict":"{}"}```', { verdict: { all_facts_preserved: true } }.to_json, { other: 'x' }.to_json].each do |message|
      stub_llm(message: message)
      expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
    end
  end

  it 'fails closed on a duplicate envelope verdict key' do
    stub_llm(message: "{\"verdict\": #{inner.to_json}, \"verdict\": #{inner.to_json}}")
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed on a provider error' do
    stub_llm(message: nil, success: false)
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed when the Response Generator is not configured (no provider call)' do
    llm = stub_llm(message: verdict, configured: false)
    expect(llm).not_to receive(:chat)
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed on a raised provider exception' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat).and_raise(StandardError, 'boom')
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed (no provider call) on a blank packet language or blank candidate' do
    expect(Marine::Llm::BaseService).not_to receive(:new)
    expect(verifier.call(packet: { customer_language: '  ' }, candidate: candidate)).to be(false)
    expect(verifier.call(packet: { customer_language: 'id' }, candidate: '   ')).to be(false)
    expect(verifier.call(packet: 'nope', candidate: candidate)).to be(false)
  end
end
