# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Conversation::Eligibility do
  subject(:eligibility) { described_class.new(conversation: conversation) }

  let(:conversation) { create(:conversation) }
  let(:account) { conversation.account }
  let(:agent) { create(:user, account: account, role: :agent) }

  def outgoing(**attrs)
    create(:message, { conversation: conversation, account: account, inbox: conversation.inbox, message_type: :outgoing }.merge(attrs))
  end

  describe 'terminal states' do
    it 'is ineligible when the conversation is resolved' do
      conversation.update!(status: :resolved)

      decision = eligibility.decision
      expect(decision.eligible?).to be(false)
      expect(decision.reason).to eq('resolved')
    end

    it 'is ineligible when the conversation is snoozed' do
      conversation.update!(status: :snoozed, snoozed_until: 1.day.from_now)

      decision = eligibility.decision
      expect(decision.eligible?).to be(false)
      expect(decision.reason).to eq('snoozed')
    end
  end

  describe 'human takeover' do
    it 'is a takeover on a public outgoing message from a User agent' do
      outgoing(sender: agent, private: false)

      decision = eligibility.decision
      expect(decision.eligible?).to be(false)
      expect(decision.reason).to eq('human_takeover')
    end

    it 'is a takeover on a public external_echo (a reply sent from the native app)' do
      outgoing(sender: create(:contact, account: account), private: false, content_attributes: { 'external_echo' => true })

      decision = eligibility.decision
      expect(decision.eligible?).to be(false)
      expect(decision.reason).to eq('human_takeover')
    end
  end

  describe 'non-takeover messages' do
    it 'does not treat a private User note as a takeover' do
      outgoing(sender: agent, private: true)

      decision = eligibility.decision
      expect(decision.eligible?).to be(true)
      expect(decision.reason).to eq('eligible')
    end

    it 'does not treat a Marine assistant outgoing reply as a takeover' do
      outgoing(sender: create(:marine_assistant, account: account), private: false)

      decision = eligibility.decision
      expect(decision.eligible?).to be(true)
      expect(decision.reason).to eq('eligible')
    end

    it 'does not treat external_echo false as a takeover' do
      outgoing(sender: create(:contact, account: account), private: false, content_attributes: { 'external_echo' => false })

      decision = eligibility.decision
      expect(decision.eligible?).to be(true)
      expect(decision.reason).to eq('eligible')
    end

    it 'does not treat a stringified external_echo "false" as a takeover' do
      outgoing(sender: create(:contact, account: account), private: false, content_attributes: { 'external_echo' => 'false' })

      decision = eligibility.decision
      expect(decision.eligible?).to be(true)
      expect(decision.reason).to eq('eligible')
    end
  end

  describe 'active handoff' do
    def activate_handoff!
      Marine::Circuit::HandoffStateStore.new(conversation: conversation.reload).activate!(message_ids: [1])
    end

    it 'is a terminal active_handoff decision once Marine has announced handoff' do
      activate_handoff!

      decision = eligibility.decision
      expect(decision.eligible?).to be(false)
      expect(decision.reason).to eq('active_handoff')
    end

    it 'stays terminal after the same conversation is resolved and reopened' do
      activate_handoff!
      conversation.update!(status: :resolved)
      conversation.update!(status: :open)

      expect(eligibility.decision.eligible?).to be(false)
      expect(eligibility.decision.reason).to eq('active_handoff')
    end

    it 'fails closed: a present-but-malformed handoff marker is a terminal active_handoff decision' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'handoff_v1' => { 'status' => 'active' } } })

      decision = eligibility.decision
      expect(decision.eligible?).to be(false)
      expect(decision.reason).to eq('active_handoff')
    end

    it 'is eligible again once the marker is cleared (a fresh window re-engagement)' do
      activate_handoff!
      Marine::Circuit::HandoffStateStore.new(conversation: conversation.reload).reset!

      decision = eligibility.decision
      expect(decision.eligible?).to be(true)
      expect(decision.reason).to eq('eligible')
    end

    it 'still blocks on a human takeover even after the marker is cleared (takeover precedence)' do
      outgoing(sender: agent, private: false)
      activate_handoff!
      Marine::Circuit::HandoffStateStore.new(conversation: conversation.reload).reset!

      decision = eligibility.decision
      expect(decision.eligible?).to be(false)
      expect(decision.reason).to eq('human_takeover')
    end
  end

  describe 'eligible conversation' do
    it 'returns the canonical eligible decision with an incoming message present' do
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox, message_type: :incoming)

      decision = eligibility.decision
      expect(decision.eligible?).to be(true)
      expect(decision.reason).to eq('eligible')
    end
  end

  describe 'no side effects' do
    it 'does not mutate the conversation or create any message' do
      outgoing(sender: agent, private: false)

      expect { eligibility.decision }.not_to(change { conversation.reload.updated_at })
      expect { eligibility.decision }.not_to(change { conversation.messages.count })
    end
  end
end
