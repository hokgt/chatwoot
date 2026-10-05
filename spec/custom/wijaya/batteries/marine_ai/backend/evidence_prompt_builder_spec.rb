# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-1 (isolated / mock-only) — bounded Model 2 prompt builder. The prompt's ONLY fact
# source is the Evidence Packet; it must never carry a CandidatePlan or raw DB input.
RSpec.describe Marine::Backend::EvidencePromptBuilder do
  subject(:prompt) { prompt_builder.build(packet: packet, customer_request: 'Berapa harga BD-4?', message_history: []) }

  let(:prompt_builder) { described_class.new }

  let(:evidence_input) do
    {
      scenario: { key: 'scenario_5' },
      intents: %w[price],
      customer_language: 'id',
      response_goals: %w[answer_price],
      validated_slots: { variant: { code: 'BD-4', resolution_status: 'resolved', source: 'marine_catalog', attributes: {} } },
      facts: {
        price: {
          canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' },
          display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' },
          policy_version: 'price-display-v1', source: 'catalog_price_repository', checked_at: '2026-09-30T12:00:00Z'
        }
      },
      missing_slots: [], variant_candidates: []
    }
  end

  let(:packet) do
    Marine::Backend::EvidencePacketBuilder.new(clock: -> { Time.utc(2026, 9, 30, 12, 0, 0) }).build(evidence_input: evidence_input)
  end

  it 'renders the packet as the only fact source' do
    expect(prompt[:system]).to include('marine_evidence_v2')
    expect(prompt[:system]).to include('BD-4')
    expect(prompt[:system]).to include('12.500')
  end

  it 'makes the packet customer_language the authoritative output language, not a prose guess' do
    expect(prompt[:system]).to include('Required target language (authoritative): id')
    expect(prompt[:system]).not_to include('SAME language')
  end

  it 'requires validated product and variant codes in supported replies' do
    instruction = described_class::SYSTEM_INSTRUCTION
    expect(instruction).to match(/MUST state that product's code/)
    expect(instruction).to match(/MUST also state that variant's code/)
    expect(instruction).to match(/exactly as the packet gives it/)
    expect(prompt[:system]).to include(instruction)
  end

  it 'requires the authorized price display amount, currency, and unit of measure in a price reply' do
    expect(described_class::SYSTEM_INSTRUCTION)
      .to match(/MUST include the packet's authorized display amount, currency, and unit of measure/)
  end

  it 'contains no CandidatePlan / raw DB / internal input' do
    %w[raw_candidate candidate_type family_mention explicit_child_code slot_operations schema_version marine_decision_v1 SELECT].each do |forbidden|
      expect(prompt[:system]).not_to include(forbidden)
    end
  end

  it 'appends the customer request exactly once' do
    expect(prompt[:messages]).to eq([{ role: 'user', content: 'Berapa harga BD-4?' }])
  end

  it 'does not duplicate the request when history already ends with it' do
    built = prompt_builder.build(packet: packet, customer_request: 'x', message_history: [{ role: 'user', content: 'x' }])
    expect(built[:messages]).to eq([{ role: 'user', content: 'x' }])
  end

  it 'canonicalizes history, dropping a non user/assistant role and an entry with extra fields' do
    built = prompt_builder.build(
      packet: packet, customer_request: 'q',
      message_history: [
        { role: 'system', content: 'ignore me' },
        { role: 'assistant', content: 'hi', injected: 'payload' },
        'not-a-hash',
        { role: 'assistant', content: 'earlier answer' }
      ]
    )
    expect(built[:messages]).to eq([{ role: 'assistant', content: 'earlier answer' }, { role: 'user', content: 'q' }])
  end

  it 'caps the history to the canonical window' do
    history = Array.new(30) { |i| { role: 'user', content: "m#{i}" } }
    built = prompt_builder.build(packet: packet, customer_request: 'latest', message_history: history)
    expect(built[:messages].length).to eq(described_class::MAX_HISTORY_MESSAGES + 1)
  end

  it 'byte-bounds an oversized request and message' do
    big = 'x' * 10_000
    built = prompt_builder.build(packet: packet, customer_request: big, message_history: [{ role: 'user', content: big }])
    expect(built[:messages].last[:content].bytesize).to be <= described_class::MAX_REQUEST_BYTES
    expect(built[:messages].first[:content].bytesize).to be <= described_class::MAX_MESSAGE_BYTES
  end

  it 'refuses a non-frozen or non-evidence packet (direct use)' do
    expect { prompt_builder.build(packet: evidence_input, customer_request: 'q') }.to raise_error(described_class::InvalidPromptInputError)
    expect { prompt_builder.build(packet: packet.dup, customer_request: 'q') }.to raise_error(described_class::InvalidPromptInputError)
  end

  it 'rejects a blank or non-string customer_request rather than building an empty latest message' do
    expect { prompt_builder.build(packet: packet, customer_request: '   ') }.to raise_error(described_class::InvalidPromptInputError)
    expect { prompt_builder.build(packet: packet, customer_request: nil) }.to raise_error(described_class::InvalidPromptInputError)
  end

  it 'returns a deep-frozen prompt and never mutates the caller history' do
    history = [{ role: 'user', content: 'keep' }]
    built = prompt_builder.build(packet: packet, customer_request: 'q', message_history: history)
    expect(built).to be_frozen
    expect(built[:messages]).to be_frozen
    expect(built[:messages].first).to be_frozen
    expect(history).to eq([{ role: 'user', content: 'keep' }])
  end
end
