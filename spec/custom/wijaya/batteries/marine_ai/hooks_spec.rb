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

  describe '.inbox_marine_assistant_id' do
    it 'returns the linked assistant id' do
      inbox = double('inbox', marine_assistant: double('assistant', id: 42))

      expect(described_class.inbox_marine_assistant_id(inbox: inbox)).to eq(42)
    end

    it 'returns nil when no assistant is linked' do
      inbox = double('inbox', marine_assistant: nil)

      expect(described_class.inbox_marine_assistant_id(inbox: inbox)).to be_nil
    end

    it 'returns nil when the inbox does not implement marine_assistant' do
      expect(described_class.inbox_marine_assistant_id(inbox: Object.new)).to be_nil
    end
  end

  describe '.claim_message_templates!' do
    let(:assistant) { double('assistant') }
    let(:messages) { double('messages') }
    let(:inbox) { double('inbox', marine_assistant: assistant) }
    let(:conversation) do
      double('conversation', resolved?: false, snoozed?: false, messages: messages, inbox: inbox, account: double('account'))
    end

    before do
      # Marine is handling the conversation: no human (User) outgoing reply yet, so the
      # outgoing/where/where/empty? chain resolves to true.
      allow(messages).to receive(:outgoing).and_return(messages)
      allow(messages).to receive(:where).and_return(messages)
      allow(messages).to receive(:empty?).and_return(true)
    end

    it 'claims (returns true) and schedules the response bound to the exact incoming message id' do
      message = double('message', incoming?: true, id: 4242, attachments: double(blank?: true))
      expect(Marine::Conversation::ResponseBuilderJob).to receive(:perform_later).with(conversation, assistant, 4242)

      expect(described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)).to be(true)
    end

    it 'does not claim for a non-Marine inbox (native templates run)' do
      allow(inbox).to receive(:marine_assistant).and_return(nil)
      message = double('message', incoming?: true)

      expect(described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)).to be(false)
    end
  end
end
