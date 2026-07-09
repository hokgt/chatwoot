# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Marine::Hooks do
  describe '.after_conversation_resolved' do
    let(:assistant) { double('assistant', feature_memory: true) }
    let(:inbox) { double('inbox', marine_assistant: assistant) }
    let(:account) { double('account') }
    let(:conversation) { double('conversation', inbox: inbox, account: account) }

    it 'enqueues the job when the inbox is Marine-linked and feature_memory is enabled' do
      expect(Marine::Memory::GenerateContactNotesJob).to receive(:perform_later).with(conversation)

      described_class.after_conversation_resolved(conversation)
    end

    it 'does not enqueue when the inbox has no Marine assistant' do
      allow(inbox).to receive(:marine_assistant).and_return(nil)
      expect(Marine::Memory::GenerateContactNotesJob).not_to receive(:perform_later)

      described_class.after_conversation_resolved(conversation)
    end

    it 'does not enqueue when feature_memory is disabled' do
      allow(assistant).to receive(:feature_memory).and_return(nil)
      expect(Marine::Memory::GenerateContactNotesJob).not_to receive(:perform_later)

      described_class.after_conversation_resolved(conversation)
    end

    it 'is a safe no-op for a nil conversation' do
      expect(Marine::Memory::GenerateContactNotesJob).not_to receive(:perform_later)

      expect { described_class.after_conversation_resolved(nil) }.not_to raise_error
    end
  end
end
