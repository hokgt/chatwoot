# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Memory::CheckpointJob do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:marine_assistant, account: account, config: { 'feature_memory' => true }) }

  before { MarineInbox.create!(inbox: inbox, marine_assistant: assistant) }

  it 'uses the shared writer with cron provenance for open, pending, and resolved conversations' do
    conversations = %i[open pending resolved].map do |status|
      create(:conversation, account: account, inbox: inbox, contact: contact, status: status)
    end
    services = conversations.index_with do
      instance_double(Marine::Memory::ContactNotesService, generate_and_store: { ok: true, created: 0 })
    end
    conversations.each do |conversation|
      allow(Marine::Memory::ContactNotesService).to receive(:new)
        .with(assistant: assistant, conversation: conversation).and_return(services.fetch(conversation))
    end

    described_class.perform_now

    services.each_value do |service|
      expect(service).to have_received(:generate_and_store).with(trigger_source: 'cron_fallback').once
    end
  end

  it 'continues to a later eligible conversation when an earlier link fails' do
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, status: :open)
    healthy_link = MarineInbox.find_by!(inbox: inbox, marine_assistant: assistant)
    broken_link = double('broken_link')
    relation = double('marine_inbox_relation')
    service = instance_double(Marine::Memory::ContactNotesService,
                              generate_and_store: { ok: true, created: 0 })

    allow(broken_link).to receive(:marine_assistant).and_raise(ActiveRecord::RecordNotFound, 'broken association')
    allow(relation).to receive(:find_each).and_yield(broken_link).and_yield(healthy_link)
    allow(MarineInbox).to receive(:includes).with(:marine_assistant, :inbox).and_return(relation)
    allow(Marine::Memory::ContactNotesService).to receive(:new)
      .with(assistant: assistant, conversation: conversation).and_return(service)
    allow(ChatwootExceptionTracker).to receive(:new).and_call_original

    described_class.perform_now

    expect(service).to have_received(:generate_and_store).with(trigger_source: 'cron_fallback').once
    expect(ChatwootExceptionTracker).to have_received(:new).with(instance_of(ActiveRecord::RecordNotFound))
  end

  it 'does not scan snoozed conversations or disabled assistants' do
    create(:conversation, account: account, inbox: inbox, contact: contact, status: :snoozed)
    assistant.update!(config: { 'feature_memory' => false })

    expect(Marine::Memory::ContactNotesService).not_to receive(:new)
    described_class.perform_now
  end
end
