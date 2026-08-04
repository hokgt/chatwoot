# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Memory::GenerateContactNotesJob do
  let(:assistant) { double('assistant', feature_memory: true) }
  let(:inbox) { double('inbox', marine_assistant: assistant) }
  let(:account) { double('account') }
  let(:conversation) { double('conversation', inbox: inbox, account: account) }
  let(:service) { instance_double(Marine::Memory::ContactNotesService, generate_and_store: { ok: true, created: 1, error: nil }) }

  it 'does nothing when the conversation is missing' do
    expect(Marine::Memory::ContactNotesService).not_to receive(:new)

    described_class.new.perform(nil)
  end

  it 'does nothing when the inbox has no Marine assistant' do
    allow(inbox).to receive(:marine_assistant).and_return(nil)
    expect(Marine::Memory::ContactNotesService).not_to receive(:new)

    described_class.new.perform(conversation)
  end

  it 'does nothing when feature_memory is disabled' do
    allow(assistant).to receive(:feature_memory).and_return(nil)
    expect(Marine::Memory::ContactNotesService).not_to receive(:new)

    described_class.new.perform(conversation)
  end

  it 'generates notes when Marine-linked and feature_memory is enabled' do
    expect(Marine::Memory::ContactNotesService).to receive(:new)
      .with(assistant: assistant, conversation: conversation).and_return(service)
    expect(service).to receive(:generate_and_store)

    described_class.new.perform(conversation)
  end
end
