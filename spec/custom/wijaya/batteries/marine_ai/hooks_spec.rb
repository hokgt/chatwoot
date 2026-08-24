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
    # channel_type is read by the handoff-window check via the core MessageWindowService; a
    # windowless channel makes the window blank so an active marker stays terminal here.
    let(:inbox) { double('inbox', marine_assistant: assistant, channel_type: 'Channel::WebWidget') }
    let(:conversation) do
      double('conversation', resolved?: false, snoozed?: false, messages: messages, inbox: inbox,
                             account: double('account'), additional_attributes: {})
    end
    let(:active_handoff_attributes) do
      { 'wijaya_marine_ai' => { 'handoff_v1' => { 'version' => 1, 'status' => 'active',
                                                  'announced_at' => '2026-01-01T00:00:00Z', 'message_ids' => [] } } }
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

    it 'still claims templates but schedules no response while a handoff is active' do
      allow(conversation).to receive(:additional_attributes).and_return(active_handoff_attributes)
      message = double('message', incoming?: true, id: 77, attachments: double(blank?: true))
      expect(Marine::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      expect(described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)).to be(true)
    end
  end

  describe '.should_process_marine_response?' do
    let(:assistant) { double('assistant') }
    let(:messages) { double('messages') }
    let(:inbox) { double('inbox', marine_assistant: assistant) }
    let(:message) { double('message', incoming?: true) }
    let(:conversation) do
      double('conversation', resolved?: false, snoozed?: false, messages: messages, additional_attributes: {})
    end

    before do
      allow(messages).to receive(:outgoing).and_return(messages)
      allow(messages).to receive(:where).and_return(messages)
      allow(messages).to receive(:empty?).and_return(true)
    end

    it 'processes an inbound turn with no takeover and no active handoff' do
      expect(described_class.should_process_marine_response?(conversation, inbox, message)).to be(true)
    end

    it 'does not process while a handoff is active' do
      allow(conversation).to receive(:additional_attributes).and_return(
        'wijaya_marine_ai' => { 'handoff_v1' => { 'version' => 1, 'status' => 'active',
                                                  'announced_at' => '2026-01-01T00:00:00Z', 'message_ids' => [] } }
      )

      expect(described_class.should_process_marine_response?(conversation, inbox, message)).to be(false)
    end

    it 'fails closed: does not process while a present-but-malformed handoff marker exists' do
      allow(conversation).to receive(:additional_attributes).and_return(
        'wijaya_marine_ai' => { 'handoff_v1' => { 'status' => 'active' } }
      )

      expect(described_class.should_process_marine_response?(conversation, inbox, message)).to be(false)
    end
  end

  # Real-record lifecycle regression for the handoff window. Reproduces Conversation 102
  # (a WhatsApp/24h conversation handed off with NO human takeover, then permanently silent
  # even after the window lapsed) generically — no hardcoded Conversation 102 timestamps.
  describe '.claim_message_templates! handoff window lifecycle (WhatsApp 24h)' do
    let(:channel) { create(:channel_whatsapp, sync_templates: false, validate_provider_config: false) }
    let(:inbox) { channel.inbox }
    let(:account) { inbox.account }
    let(:assistant) { create(:marine_assistant, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox).reload }
    let(:contact) { create(:contact, account: account) }
    let(:anchor) { Time.zone.parse('2026-08-21T08:00:00Z') }

    def incoming_at(time)
      create(:message, conversation: conversation, account: account, inbox: inbox,
                       message_type: :incoming, sender: contact, created_at: time)
    end

    def marker_active?
      Marine::Circuit::HandoffStateStore.new(conversation: conversation.reload).active?
    end

    # Marine-linked inbox, a prior inbound turn (window anchor), and an already-active marker.
    before do
      MarineInbox.create!(inbox: inbox, marine_assistant: assistant)
      @prior = incoming_at(anchor)
      Marine::Circuit::HandoffStateStore.new(conversation: conversation).activate!(message_ids: [])
    end

    it 'stays silent for a later inbound still inside the active window and keeps the marker' do
      message = incoming_at(anchor + 23.hours)
      expect(Marine::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)

      expect(marker_active?).to be(true)
    end

    it 'clears the marker and schedules a fresh response for the first inbound after the window lapses' do
      message = incoming_at(anchor + 50.hours)
      expect(Marine::Conversation::ResponseBuilderJob).to receive(:perform_later).with(conversation, assistant, message.id)

      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)

      expect(marker_active?).to be(false)
    end

    it 'keeps an explicit human takeover blocking after the window lapses (no reset, no schedule)' do
      create(:message, conversation: conversation, account: account, inbox: inbox,
                       message_type: :outgoing, private: false, sender: create(:user, account: account, role: :agent))
      message = incoming_at(anchor + 50.hours)
      expect(Marine::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      expect(described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)).to be(false)
    end

    it 'creates no message or outbound content while clearing the lapsed marker' do
      message = incoming_at(anchor + 50.hours)
      allow(Marine::Conversation::ResponseBuilderJob).to receive(:perform_later)

      expect { described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message) }
        .not_to(change { conversation.reload.messages.outgoing.count })
    end
  end
end
