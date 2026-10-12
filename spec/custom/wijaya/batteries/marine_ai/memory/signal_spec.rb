# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/MultipleDescribes -- Signal and its projection share one focused contract fixture.

RSpec.describe Marine::Memory::Signal do
  let(:account) { create(:account) }
  let(:attributes) do
    {
      status: 'complete', requested_capabilities: ['price'], delivered_capabilities: ['price'],
      evidence_versions: ['marine_evidence_v2'], public_reply_message_id: reply.id
    }
  end
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:marine_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:trigger) do
    create(:message, conversation: conversation, account: account, inbox: inbox, sender: contact,
                     message_type: :incoming, private: false, content: 'synthetic request')
  end
  let(:reply) do
    create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                     message_type: :outgoing, private: false, content: 'synthetic reply')
  end

  before { MarineInbox.create!(inbox: inbox, marine_assistant: assistant) }

  def complete_claim
    claim = Marine::Conversation::ProcessingClaim.new(message: trigger)
    owner = claim.acquire!
    claim.complete!(claim_id: owner.claim['claim_id'])
  end

  it 'persists and trusts only the exact fact-free shape on a public incoming carrier with a completed claim' do
    complete_claim
    described_class.write!(message: trigger, **attributes)

    signal = described_class.extract(trigger.reload)
    expect(signal.keys).to match_array(described_class::KEYS)
    expect(signal).to eq(
      'schema_version' => 'marine_memory_signal_v1', 'status' => 'complete',
      'requested_capabilities' => ['price'], 'delivered_capabilities' => ['price'],
      'evidence_versions' => ['marine_evidence_v2'], 'public_reply_message_id' => reply.id
    )
    expect(signal.to_json).not_to match(/synthetic|prompt|quantity|location|price_value|stock_value/)
  end

  it 'rejects an uncompleted claim, extra keys, unknown values, duplicates, and a foreign reply' do
    expect { described_class.write!(message: trigger, **attributes) }.to raise_error(ArgumentError, /completed processing claim/)
    complete_claim

    valid = described_class.build(**attributes)
    expect(described_class.valid_shape?(valid.merge('raw_text' => 'forbidden'))).to be(false)
    expect(described_class.valid_shape?(valid.merge('status' => 'maybe'))).to be(false)
    expect(described_class.valid_shape?(valid.merge('requested_capabilities' => %w[price price]))).to be(false)
    expect(described_class.valid_shape?(valid.merge('evidence_versions' => ['marine_evidence_unknown']))).to be(false)

    other = create(:conversation, account: account, inbox: inbox, contact: contact)
    foreign_reply = create(:message, conversation: other, account: account, inbox: inbox,
                                     message_type: :outgoing, private: false, content: 'other')
    described_class.write!(message: trigger, **attributes.merge(public_reply_message_id: foreign_reply.id))
    expect(described_class.extract(trigger.reload)).to be_nil
  end

  it 'rejects human, stale/pre-trigger, foreign-assistant, and wrong-inbox replies' do
    complete_claim
    other_assistant = create(:marine_assistant, account: account)
    other_inbox = create(:inbox, account: account)
    candidates = [
      create(:message, conversation: conversation, account: account, inbox: inbox, sender: contact,
                       message_type: :outgoing, private: false),
      create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                       message_type: :outgoing, private: false, created_at: trigger.created_at - 1.minute),
      create(:message, conversation: conversation, account: account, inbox: inbox, sender: other_assistant,
                       message_type: :outgoing, private: false),
      create(:message, conversation: conversation, account: account, inbox: other_inbox, sender: assistant,
                       message_type: :outgoing, private: false)
    ]

    candidates.each do |candidate|
      described_class.write!(message: trigger, **attributes.merge(public_reply_message_id: candidate.id))
      expect(described_class.extract(trigger.reload)).to be_nil
    end
  end

  it 'requires every requested capability to be delivered for complete and permits blocking with no reply' do
    expect do
      described_class.build(**attributes, requested_capabilities: %w[price stock], delivered_capabilities: ['price'])
    end.to raise_error(ArgumentError)

    blocking = described_class.build(
      status: 'blocking', requested_capabilities: %w[price stock], delivered_capabilities: ['price'],
      evidence_versions: ['marine_evidence_v2'], public_reply_message_id: nil
    )
    expect(blocking['status']).to eq('blocking')
  end
end

RSpec.describe Marine::Memory::SignalProjection do
  Result = Marine::Backend::ExactPriceCustomerExecution::Result

  def backend_result(requested:, delivered:, status: :deliverable, versions: ['marine_evidence_v2'], reason: nil)
    reason ||= status == :deliverable ? :accepted : :synthetic
    Result.new(status: status, reason: reason, text: 'reply', requested_capabilities: requested,
               delivered_capabilities: delivered, evidence_versions: versions).freeze
  end

  it 'marks all-requested authoritative delivery complete and a partial multi-intent result blocking' do
    complete = described_class.new(
      response: { 'response' => 'reply' },
      backend_result: backend_result(requested: %w[price stock], delivered: %w[price stock]),
      public_reply_message_id: 10
    ).to_h
    partial = described_class.new(
      response: { 'response' => 'reply' },
      backend_result: backend_result(requested: %w[price stock], delivered: ['price']),
      public_reply_message_id: 11
    ).to_h

    expect(complete).to include(status: 'complete', requested_capabilities: %w[price stock],
                                delivered_capabilities: %w[price stock], evidence_versions: ['marine_evidence_v2'])
    expect(partial).to include(status: 'blocking')
  end

  it 'rejects unknown Backend evidence versions from the closed projection' do
    projection = described_class.new(
      response: { 'response' => 'reply' },
      backend_result: backend_result(requested: ['price'], delivered: ['price'], versions: ['marine_evidence_unknown']),
      public_reply_message_id: 10
    ).to_h

    expect(projection).to include(status: 'complete', evidence_versions: [])
  end

  it 'marks silent handoff and terminal no-output blocking despite no public reply' do
    handoff = described_class.new(
      response: { 'action' => 'handoff' }, backend_result: nil, public_reply_message_id: nil
    ).to_h
    terminal = described_class.new(
      response: { 'action' => 'terminal_no_output' }, backend_result: nil, public_reply_message_id: nil
    ).to_h

    expect(handoff).to include(status: 'blocking', public_reply_message_id: nil)
    expect(terminal).to include(status: 'blocking', public_reply_message_id: nil)
  end

  it 'marks only a structurally proven non-product outcome neutral without reading prose' do
    neutral = backend_result(requested: [], delivered: [], status: :neutral, versions: [], reason: :non_product)
    projection = described_class.new(
      response: { 'response' => 'anything at all' }, backend_result: neutral, public_reply_message_id: 12
    ).to_h
    unknown = described_class.new(
      response: { 'response' => 'hello' }, backend_result: nil, public_reply_message_id: 13
    ).to_h

    expect(projection).to include(status: 'neutral', requested_capabilities: [], delivered_capabilities: [])
    expect(unknown).to include(status: 'blocking')
  end

  it 'fails closed for early Backend failure and an unmapped/unknown Backend product outcome' do
    early_failure = backend_result(requested: [], delivered: [], status: :fallback, versions: [], reason: :relationship_invalid)
    unknown_product = backend_result(requested: ['price'], delivered: ['price'], status: :unknown)

    expect(described_class.new(response: { 'response' => 'fallback' }, backend_result: early_failure,
                               public_reply_message_id: 14).to_h).to include(status: 'blocking')
    expect(described_class.new(response: { 'response' => 'fallback' }, backend_result: unknown_product,
                               public_reply_message_id: 15).to_h).to include(
                                 status: 'blocking', requested_capabilities: ['price'], delivered_capabilities: []
                               )
  end

  it 'maps legacy parent/variant information as requested but not delivered without approved-description authority' do
    %i[parent_info variant_info].each do |kind|
      response = { 'product_plan' => { action: :reply, reply: { kind: kind },
                                       state: { changes: { 'current_intent' => kind.to_s } } } }
      projection = described_class.new(response: response, backend_result: nil, public_reply_message_id: 16).to_h
      expect(projection).to include(status: 'blocking', requested_capabilities: ['product_information'],
                                    delivered_capabilities: [])
    end
  end
end
# rubocop:enable RSpec/MultipleDescribes
