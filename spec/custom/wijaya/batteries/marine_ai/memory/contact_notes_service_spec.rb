# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Memory::ContactNotesService do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:marine_assistant, account: account, config: { 'feature_memory' => true }) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :open) }
  let(:base_service) { instance_double(Marine::Llm::BaseService, configured?: true) }

  before do
    MarineInbox.create!(inbox: inbox, marine_assistant: assistant)
    allow(Marine::Llm::BaseService).to receive(:new).with(account: account).and_return(base_service)
    allow(base_service).to receive(:complete).and_return(ok: true, message: 'Customer prefers email contact.', error: nil)
  end

  def incoming(content, at: Time.current)
    create(:message, conversation: conversation, account: account, inbox: inbox, sender: contact,
                     message_type: :incoming, private: false, content: content, created_at: at)
  end

  def outgoing(content, at: Time.current)
    create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                     message_type: :outgoing, private: false, content: content, created_at: at)
  end

  def memory_notes
    conversation.messages.where(private: true, message_type: :outgoing)
  end

  def resolve_conversation
    conversation.update!(status: :resolved)
  end

  it 'stores exactly one human-readable marked private Message and never a Contact Note for a final summary' do
    first = incoming('Please remember that email is best.')
    last = outgoing('Understood.')
    resolve_conversation
    original_status = conversation.status
    original_assignee = conversation.assignee_id

    original_contact_note_count = contact.notes.count
    expect { described_class.new(assistant: assistant, conversation: conversation).generate_and_store(state: 'final') }
      .to change(memory_notes, :count).by(1)
    expect(contact.notes.count).to eq(original_contact_note_count)

    note = memory_notes.last
    marker = note.additional_attributes.fetch(Marine::Memory::Marker::KEY)
    expect(note).to have_attributes(private: true, content: include('Customer prefers email contact.'))
    expect(marker).to include(
      'version' => 1,
      'kind' => 'marine_long_term_memory',
      'state' => 'final',
      'source_account_id' => account.id,
      'source_contact_id' => contact.id,
      'source_conversation_id' => conversation.id,
      'start_public_message_id' => first.id,
      'end_public_message_id' => last.id,
      'generator' => 'marine_llm_v1'
    )
    expect(marker.fetch('transcript_fingerprint')).to match(/\A[0-9a-f]{64}\z/)
    expect(conversation.reload).to have_attributes(status: original_status, assignee_id: original_assignee)
    expect(conversation.messages.where(private: false, message_type: %i[incoming outgoing]).count).to eq(2)
  end

  it 'summarizes only public incoming/outgoing text and excludes private notes and activity' do
    incoming('PUBLIC CUSTOMER')
    outgoing('PUBLIC ASSISTANT')
    create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                     message_type: :outgoing, private: true, content: 'PRIVATE SECRET')
    create(:message, conversation: conversation, account: account, inbox: inbox,
                     message_type: :activity, private: false, content: 'ACTIVITY SECRET')
    resolve_conversation

    expect(base_service).to receive(:complete) do |prompt:, system:|
      expect(prompt).to include('PUBLIC CUSTOMER', 'PUBLIC ASSISTANT')
      expect(prompt).not_to include('PRIVATE SECRET', 'ACTIVITY SECRET')
      expect(system).to include('durable')
      { ok: true, message: 'Safe summary.', error: nil }
    end

    described_class.new(assistant: assistant, conversation: conversation).generate_and_store(state: 'final')
  end

  it 'is range/fingerprint idempotent across replay and a competing interleaving' do
    incoming('Remember this.')
    resolve_conversation
    competitor = described_class.new(assistant: assistant, conversation: conversation)
    outer = described_class.new(assistant: assistant, conversation: conversation)
    allow(outer).to receive(:summarize) do |_snapshot|
      competitor.generate_and_store(state: 'final')
      'Outer duplicate summary.'
    end

    outer.generate_and_store(state: 'final')
    described_class.new(assistant: assistant, conversation: conversation).generate_and_store(state: 'final')

    expect(memory_notes.count).to eq(1)
  end

  it 'appends only the later unsummarized public delta as a second note' do
    first = incoming('First session.', at: 2.hours.ago)
    described_class.new(assistant: assistant, conversation: conversation).generate_and_store(state: 'checkpoint')
    later = incoming('Second session.', at: 1.hour.ago)
    allow(base_service).to receive(:complete).and_return(ok: true, message: 'Second summary.', error: nil)

    described_class.new(assistant: assistant, conversation: conversation).generate_and_store(state: 'checkpoint')

    expect(memory_notes.count).to eq(2)
    markers = memory_notes.map { |note| note.additional_attributes.fetch(Marine::Memory::Marker::KEY) }
    expect(markers.map { |marker| marker['start_public_message_id'] }).to eq([first.id, later.id])
    expect(markers.map { |marker| marker['end_public_message_id'] }).to eq([first.id, later.id])
  end

  it 'does not duplicate a checkpoint on resolve without new public messages, but writes a final delta when new incoming exists' do
    incoming('Checkpointed.', at: 2.hours.ago)
    service = described_class.new(assistant: assistant, conversation: conversation)
    service.generate_and_store(state: 'checkpoint')
    resolve_conversation
    service.generate_and_store(state: 'final')
    expect(memory_notes.count).to eq(1)

    incoming('New before resolve.')
    resolve_conversation
    service.generate_and_store(state: 'final')

    expect(memory_notes.count).to eq(2)
    expect(memory_notes.last.additional_attributes.dig(Marine::Memory::Marker::KEY, 'state')).to eq('final')
  end

  it 'drops a stale generated result even when a new message lands beyond the bounded snapshot' do
    stub_const("#{described_class}::MAX_SOURCE_MESSAGES", 2)
    incoming('Snapshot me.', at: 2.hours.ago)
    outgoing('Initial bounded reply.', at: 2.hours.ago)
    service = described_class.new(assistant: assistant, conversation: conversation)
    allow(service).to receive(:summarize) do |_snapshot|
      incoming('Arrived during generation.')
      'Now stale.'
    end

    result = service.generate_and_store(state: 'checkpoint')

    expect(result).to include(ok: false, created: 0, error: 'stale_snapshot')
    expect(memory_notes).to be_empty
  end

  it 'keeps historical product identity advisory while excluding current price and stock claims from memory' do
    incoming('Remember the family and variant I selected.', at: 1.hour.ago)

    expect(base_service).to receive(:complete) do |prompt:, system:|
      expect(prompt).to include('family and variant')
      expect(system).to include('historical product family', 'advisory context')
      expect(system).to include('Never preserve price or stock as current facts')
      { ok: true, message: 'Customer previously selected a family and variant.', error: nil }
    end

    described_class.new(assistant: assistant, conversation: conversation).generate_and_store(state: 'checkpoint')
  end

  it 'fails closed when the assistant is disabled or is not the conversation inbox assistant' do
    incoming('Do not summarize through an unrelated assistant.')
    unrelated = create(:marine_assistant, account: account, config: { 'feature_memory' => true })
    assistant.update!(config: { 'feature_memory' => false })

    expect(base_service).not_to receive(:complete)
    disabled = described_class.new(assistant: assistant, conversation: conversation).generate_and_store
    mismatched = described_class.new(assistant: unrelated, conversation: conversation).generate_and_store

    expect(disabled).to include(created: 0, error: 'memory_disabled')
    expect(mismatched).to include(created: 0, error: 'assistant_mismatch')
    expect(memory_notes).to be_empty
  end

  it 'requires at least one new public incoming message' do
    outgoing('Assistant only.')
    expect(base_service).not_to receive(:complete)
    expect(described_class.new(assistant: assistant, conversation: conversation).generate_and_store(state: 'checkpoint'))
      .to include(created: 0, error: 'no_new_incoming')
  end

  it 'safely folds LLM failure' do
    incoming('Customer turn.')
    resolve_conversation
    allow(base_service).to receive(:complete).and_raise(StandardError, 'provider failed')
    expect { described_class.new(assistant: assistant, conversation: conversation).generate_and_store(state: 'final') }
      .not_to raise_error
    expect(memory_notes).to be_empty
  end

  it 'reloads lifecycle status before calling the provider' do
    incoming('Resolve then reopen elsewhere.')
    resolve_conversation
    service = described_class.new(assistant: assistant, conversation: conversation)
    Conversation.where(id: conversation.id).update_all(status: Conversation.statuses[:open]) # rubocop:disable Rails/SkipsModelValidations

    expect(conversation.status).to eq('resolved')
    expect(base_service).not_to receive(:complete)
    expect(service.generate_and_store(state: 'final'))
      .to include(created: 0, error: 'conversation_not_resolved')
  end

  it 'rechecks checkpoint quietness before calling the provider' do
    incoming('Initially quiet.', at: 2.hours.ago)
    service = described_class.new(assistant: assistant, conversation: conversation)
    expect(service.checkpoint_eligible?).to be(true)
    incoming('Recent activity.', at: Time.current)

    expect(base_service).not_to receive(:complete)
    expect(service.generate_and_store(state: 'checkpoint'))
      .to include(created: 0, error: 'checkpoint_not_quiet')
  end

  it 'drops a final summary if the conversation reopens during generation' do
    incoming('Resolve this conversation.')
    resolve_conversation
    service = described_class.new(assistant: assistant, conversation: conversation)
    allow(service).to receive(:summarize) do |_snapshot|
      conversation.update!(status: :open)
      'Stale final summary.'
    end

    expect(service.generate_and_store(state: 'final'))
      .to include(created: 0, error: 'conversation_not_resolved')
    expect(memory_notes).to be_empty
  end

  it 'drops a checkpoint if the conversation resolves during generation' do
    incoming('Quiet checkpoint.', at: 2.hours.ago)
    service = described_class.new(assistant: assistant, conversation: conversation)
    allow(service).to receive(:summarize) do |_snapshot|
      resolve_conversation
      'Stale checkpoint summary.'
    end

    expect(service.generate_and_store(state: 'checkpoint'))
      .to include(created: 0, error: 'checkpoint_ineligible_status')
    expect(memory_notes).to be_empty
  end
end
