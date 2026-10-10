# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Memory::CheckpointJob do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:marine_assistant, account: account, config: { 'feature_memory' => true }) }
  let(:base_service) do
    instance_double(Marine::Llm::BaseService, configured?: true,
                                              complete: { ok: true, message: 'Durable customer memory.', error: nil })
  end

  before do
    MarineInbox.create!(inbox: inbox, marine_assistant: assistant)
    allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
  end

  def conversation(status: :open, target_inbox: inbox)
    create(:conversation, account: account, inbox: target_inbox, contact: contact, status: status)
  end

  def incoming(target, at: 2.hours.ago)
    create(:message, conversation: target, account: account, inbox: target.inbox, sender: contact,
                     message_type: :incoming, private: false, content: 'remember me', created_at: at)
  end

  def memory_count(target)
    target.messages.where(private: true, message_type: :outgoing)
          .where('additional_attributes -> ? IS NOT NULL', Marine::Memory::Marker::KEY).count
  end

  it 'creates a checkpoint for a quiet open or pending Marine conversation with a new public incoming message' do
    open_conversation = conversation(status: :open)
    pending_conversation = conversation(status: :pending)
    incoming(open_conversation)
    incoming(pending_conversation)

    described_class.perform_now

    expect(memory_count(open_conversation)).to eq(1)
    expect(memory_count(pending_conversation)).to eq(1)
    expect(open_conversation.messages.where(private: true).last.additional_attributes
                            .dig(Marine::Memory::Marker::KEY, 'state')).to eq('checkpoint')
  end

  it 'skips no incoming, no new incoming after a checkpoint, resolved, non-Marine, disabled and recently-active conversations' do
    no_incoming = conversation
    already_summarized = conversation
    incoming(already_summarized)
    Marine::Memory::ContactNotesService.new(assistant: assistant, conversation: already_summarized)
                                       .generate_and_store(state: 'checkpoint')

    resolved = conversation(status: :resolved)
    incoming(resolved)
    resolved.update!(status: :resolved)

    foreign_inbox = create(:inbox, account: account)
    non_marine = conversation(target_inbox: foreign_inbox)
    incoming(non_marine)

    disabled_inbox = create(:inbox, account: account)
    disabled_assistant = create(:marine_assistant, account: account, config: { 'feature_memory' => false })
    MarineInbox.create!(inbox: disabled_inbox, marine_assistant: disabled_assistant)
    disabled = conversation(target_inbox: disabled_inbox)
    incoming(disabled)

    recent = conversation
    incoming(recent, at: 5.minutes.ago)

    described_class.perform_now

    expect(memory_count(no_incoming)).to eq(0)
    expect(memory_count(already_summarized)).to eq(1)
    expect(memory_count(resolved)).to eq(0)
    expect(memory_count(non_marine)).to eq(0)
    expect(memory_count(disabled)).to eq(0)
    expect(memory_count(recent)).to eq(0)
  end
end
