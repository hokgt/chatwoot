# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Circuit::HandoffWindow do
  subject(:window) { described_class.new(conversation: conversation, message: new_message) }

  # WhatsApp inbox => authoritative 24h messaging window (Conversations::MessageWindowService).
  let(:channel) { create(:channel_whatsapp, sync_templates: false, validate_provider_config: false) }
  let(:inbox) { channel.inbox }
  let(:account) { inbox.account }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:contact) { create(:contact, account: account) }

  # A base anchor time and the prior inbound turn the previous window is anchored on.
  let(:anchor) { Time.zone.parse('2026-08-21T08:00:00Z') }

  def incoming_at(time)
    create(:message, conversation: conversation, account: account, inbox: inbox,
                     message_type: :incoming, sender: contact, created_at: time)
  end

  describe '#expired? on a windowed (WhatsApp 24h) channel' do
    before { @prior = incoming_at(anchor) }

    context 'when the new inbound arrives strictly before the window closes' do
      let(:new_message) { incoming_at(anchor + 23.hours) }

      it 'is not expired (still the same active window)' do
        expect(window.expired?).to be(false)
      end
    end

    context 'when one second before the window boundary' do
      let(:new_message) { incoming_at(anchor + 24.hours - 1.second) }

      it 'is not expired (mirrors the native strict < window test)' do
        expect(window.expired?).to be(false)
      end
    end

    context 'when exactly at the window boundary' do
      let(:new_message) { incoming_at(anchor + 24.hours) }

      it 'is expired (a fresh window opens at the boundary)' do
        expect(window.expired?).to be(true)
      end
    end

    context 'when well after the window closed' do
      let(:new_message) { incoming_at(anchor + 50.hours) }

      it 'is expired (a fresh window)' do
        expect(window.expired?).to be(true)
      end
    end
  end

  describe '#expired? fail-closed cases' do
    context 'when on a channel with no applicable messaging window (web widget)' do
      let(:conversation) { create(:conversation) }
      let(:account) { conversation.account }
      let(:new_message) { incoming_at(anchor + 50.hours) }

      before { incoming_at(anchor) }

      it 'is never expired, so a handoff there stays terminal' do
        expect(conversation.can_reply?).to be(true) # no window policy
        expect(window.expired?).to be(false)
      end
    end

    context 'when there is no prior inbound turn to anchor on' do
      let(:new_message) { incoming_at(anchor + 50.hours) }

      it 'is not expired' do
        expect(window.expired?).to be(false)
      end
    end

    context 'when the candidate message is not incoming' do
      before { incoming_at(anchor) }

      let(:new_message) do
        create(:message, conversation: conversation, account: account, inbox: inbox,
                         message_type: :outgoing, created_at: anchor + 50.hours)
      end

      it 'is not expired (only an inbound turn can open a fresh window)' do
        expect(window.expired?).to be(false)
      end
    end
  end
end
