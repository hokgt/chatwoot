# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Memory::IdleSummaryJob do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:marine_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:service) do
    instance_double(Marine::Memory::ContactNotesService,
                    generate_and_store: { ok: true, created: 0, error: 'not_idle' })
  end

  it 'delegates to the shared writer with idle-timeout provenance' do
    allow(Marine::Memory::ContactNotesService).to receive(:new)
      .with(assistant: assistant, conversation: conversation).and_return(service)

    described_class.perform_now(conversation.id, assistant.id, 123)

    expect(service).to have_received(:generate_and_store).with(trigger_source: 'idle_timeout').once
  end

  it 'no-ops for missing records' do
    expect(Marine::Memory::ContactNotesService).not_to receive(:new)
    described_class.perform_now(-1, -1, 123)
  end
end
