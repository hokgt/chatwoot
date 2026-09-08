# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Circuit::HandoffService do
  subject(:service) { described_class.new(conversation: conversation, assistant: assistant, reason: reason) }

  # Reloaded so the record is clean before the service row-locks it.
  let(:conversation) { create(:conversation).reload }
  let(:account) { conversation.account }
  let(:assistant) { create(:marine_assistant, account: account) }
  let(:reason) { 'charge_error' }

  def public_outgoing
    conversation.messages.outgoing.where(private: false)
  end

  def private_notes
    conversation.messages.where(private: true)
  end

  def marker
    conversation.reload.additional_attributes.dig('wijaya_marine_ai', 'handoff_v1')
  end

  describe 'first handoff' do
    it 'creates exactly one public message and one private note, calls bot_handoff! once, sets the active marker' do
      expect(conversation).to receive(:bot_handoff!).once.and_call_original

      service.perform

      expect(public_outgoing.count).to eq(1)
      expect(public_outgoing.first.content).to eq(described_class::DEFAULT_MESSAGE)
      expect(private_notes.count).to eq(1)
      expect(private_notes.first.content).to eq("Marine Circuit handoff: #{reason}")
      expect(marker).to include('status' => 'active', 'version' => 1)
      expect(marker['message_ids']).to contain_exactly(private_notes.first.id, public_outgoing.first.id)
    end

    it 'uses the assistant-configured handoff message when present' do
      assistant.update!(config: { 'handoff_message' => 'A human will help you shortly.' })

      service.perform

      expect(public_outgoing.first.content).to eq('A human will help you shortly.')
    end

    it 'creates no private note when no reason is given' do
      described_class.new(conversation: conversation, assistant: assistant, reason: nil).perform

      expect(public_outgoing.count).to eq(1)
      expect(private_notes.count).to eq(0)
    end
  end

  describe 'idempotency (same-message replay / repeated calls)' do
    it 'does not duplicate messages, notes, or re-dispatch when called again' do
      service.perform
      expect(conversation).not_to receive(:bot_handoff!)

      described_class.new(conversation: conversation.reload, assistant: assistant, reason: reason).perform

      expect(public_outgoing.count).to eq(1)
      expect(private_notes.count).to eq(1)
    end

    it 'remains one public/private pair across many repeated calls' do
      3.times { described_class.new(conversation: conversation.reload, assistant: assistant, reason: reason).perform }

      expect(public_outgoing.count).to eq(1)
      expect(private_notes.count).to eq(1)
    end
  end

  describe 'partial failure' do
    it 'rolls back both messages and the marker when bot_handoff! fails' do
      allow(conversation).to receive(:bot_handoff!).and_raise(ActiveRecord::RecordInvalid)

      expect { service.perform }.to raise_error(ActiveRecord::RecordInvalid)

      expect(conversation.messages.reload.count).to eq(0)
      expect(marker).to be_nil
    end
  end

  describe 'eligibility gate' do
    it 'does nothing once a human agent has taken over' do
      agent = create(:user, account: account, role: :agent)
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox, message_type: :outgoing, sender: agent)

      service.perform

      expect(conversation.messages.outgoing.where(sender_type: 'Marine::Assistant').count).to eq(0)
      expect(marker).to be_nil
    end

    it 'does nothing after an external_echo human reply from the native app' do
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                       message_type: :outgoing, sender: create(:contact, account: account),
                       content_attributes: { 'external_echo' => true })
      expect(conversation).not_to receive(:bot_handoff!)

      service.perform

      expect(public_outgoing.where(content: described_class::DEFAULT_MESSAGE)).to be_empty
      expect(marker).to be_nil
    end

    it 'fails closed: a present-but-malformed marker suppresses all handoff output' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'handoff_v1' => { 'status' => 'active' } } })
      expect(conversation).not_to receive(:bot_handoff!)

      described_class.new(conversation: conversation.reload, assistant: assistant, reason: reason).perform

      expect(public_outgoing.count).to eq(0)
      expect(private_notes.count).to eq(0)
    end
  end

  describe 'lifecycle across the Conversation record' do
    it 'creates no new messages, notes, or bot_handoff after the same conversation is resolved and reopened' do
      service.perform
      public_count = public_outgoing.count
      private_count = private_notes.count

      conversation.update!(status: :resolved)
      conversation.update!(status: :open)
      reopened = conversation.reload
      expect(reopened).not_to receive(:bot_handoff!)

      described_class.new(conversation: reopened, assistant: assistant, reason: reason).perform

      expect(public_outgoing.count).to eq(public_count)
      expect(private_notes.count).to eq(private_count)
      expect(Marine::Circuit::HandoffStateStore.new(conversation: conversation.reload).active?).to be(true)
    end

    it 'is independent for a brand-new Conversation record' do
      service.perform
      other = create(:conversation, account: account, inbox: conversation.inbox).reload

      expect(Marine::Circuit::HandoffStateStore.new(conversation: other).active?).to be(false)
    end
  end
end
