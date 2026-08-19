# frozen_string_literal: true

require 'rails_helper'

# Canonical bounded conversation context + interaction-phase detection. Synthetic, generic
# text only; no customer data. All timestamps are explicit so ordering is deterministic and
# never relies on insertion/id order alone.
RSpec.describe Marine::Conversation::ContextBuilder do
  let(:conversation) { create(:conversation) }
  let(:account) { conversation.account }
  let(:marine) { create(:marine_assistant, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:base) { Time.zone.parse('2026-06-01 09:00:00') }

  # `hidden:` maps to the message `private` flag (avoids shadowing Ruby's `private`). A nil
  # sender lets the factory default it (User for outgoing, Contact for incoming); Marine
  # replies pass `sender: marine` explicitly.
  def add(type, at:, content: 'sample text', hidden: false, sender: nil)
    create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                     message_type: type, content: content, private: hidden, sender: sender, created_at: at)
  end

  def build(trigger)
    described_class.new(conversation: conversation, trigger_message: trigger).build
  end

  describe 'history ordering and selection' do
    it 'orders by created_at then id (not insertion/id order) with a deterministic id tie-break' do
      # Inserted C-first (lowest id) but latest timestamp; A and B tie on created_at so the
      # id tie-break decides A before B. Pure id ordering would wrongly yield [C, A, B].
      add(:incoming, at: base + 60, content: 'C')
      add(:outgoing, at: base + 10, sender: marine, content: 'A')
      add(:outgoing, at: base + 10, sender: marine, content: 'B')
      trigger = add(:incoming, at: base + 120, content: 'now')

      expect(build(trigger).history.map { |h| h[:content] }).to eq(%w[A B C])
    end

    it 'keeps the newest 10 eligible prior turns and returns them oldest-to-newest' do
      12.times { |i| add(:incoming, at: base + i, content: "m#{i}") }
      trigger = add(:incoming, at: base + 100, content: 'now')

      contents = build(trigger).history.map { |h| h[:content] }
      expect(contents.length).to eq(10)
      # Oldest two (m0, m1) dropped; remainder oldest-to-newest.
      expect(contents).to eq((2..11).map { |i| "m#{i}" })
    end
  end

  describe 'bounds' do
    it 'truncates each prior turn to 500 chars and the trigger to 4000 chars' do
      add(:incoming, at: base + 1, content: 'x' * 600)
      trigger = add(:incoming, at: base + 100, content: 'y' * 4500)

      result = build(trigger)
      expect(result.history.first[:content].length).to eq(500)
      expect(result.history.first[:content]).to eq('x' * 500)
      expect(result.trigger.length).to eq(4000)
      expect(result.trigger).to eq('y' * 4000)
    end
  end

  describe 'eligibility exclusions' do
    it 'excludes private notes, blank/whitespace content, and non-incoming/outgoing messages' do
      add(:outgoing, at: base + 1, sender: marine, hidden: true, content: 'private note')
      add(:incoming, at: base + 2, content: '')
      add(:incoming, at: base + 3, content: '   ')
      add(:activity, at: base + 4, content: 'system activity')
      add(:incoming, at: base + 5, content: 'real turn')
      trigger = add(:incoming, at: base + 100, content: 'now')

      expect(build(trigger).history.map { |h| h[:content] }).to eq(['real turn'])
    end

    it 'excludes tab-only and newline-only content (all POSIX whitespace, not just spaces)' do
      add(:incoming, at: base + 1, content: "\t\t")
      add(:incoming, at: base + 2, content: "\n")
      add(:incoming, at: base + 3, content: "\r\n\t ")
      add(:outgoing, at: base + 4, sender: marine, content: 'kept turn')
      trigger = add(:incoming, at: base + 100, content: 'now')

      expect(build(trigger).history.map { |h| h[:content] }).to eq(['kept turn'])
    end

    it 'selects the newest 10 AFTER excluding blank/whitespace-only turns (not fetch-then-reject)' do
      # 10 real turns are interleaved with tab/newline-only noise. A fetch-10-then-reject
      # approach would drop real turns whenever noise fell inside the newest 10 by id.
      10.times do |i|
        add(:incoming, at: base + (i * 10), content: "real#{i}")
        add(:incoming, at: base + (i * 10) + 1, content: "\t")
        add(:incoming, at: base + (i * 10) + 2, content: "\n")
      end
      trigger = add(:incoming, at: base + 1000, content: 'now')

      contents = build(trigger).history.map { |h| h[:content] }
      expect(contents).to eq((0..9).map { |i| "real#{i}" })
    end
  end

  describe 'the current trigger' do
    it 'excludes the trigger by id and provides it separately as the bounded trigger' do
      add(:incoming, at: base + 1, content: 'earlier turn')
      trigger = add(:incoming, at: base + 5, content: 'the trigger text')

      result = build(trigger)
      expect(result.history.map { |h| h[:content] }).to eq(['earlier turn'])
      expect(result.trigger).to eq('the trigger text')
    end

    it 'retains an earlier message with identical content (excluded by id, never by content)' do
      add(:incoming, at: base + 1, content: 'same words')
      trigger = add(:incoming, at: base + 5, content: 'same words')

      result = build(trigger)
      expect(result.history.map { |h| h[:content] }).to eq(['same words'])
      expect(result.trigger).to eq('same words')
    end
  end

  describe 'role mapping' do
    it 'maps incoming to user and outgoing to assistant (direction preserved for all senders)' do
      add(:incoming, at: base + 1, content: 'from customer')
      add(:outgoing, at: base + 2, sender: marine, content: 'from marine')
      add(:outgoing, at: base + 3, sender: agent, content: 'from human agent')
      trigger = add(:incoming, at: base + 100, content: 'now')

      expect(build(trigger).history).to eq(
        [{ role: 'user', content: 'from customer' },
         { role: 'assistant', content: 'from marine' },
         { role: 'assistant', content: 'from human agent' }]
      )
    end
  end

  describe 'interaction phase' do
    it 'is opening when no earlier public Marine reply exists before the trigger' do
      add(:incoming, at: base + 1, content: 'hi')
      trigger = add(:incoming, at: base + 5, content: 'question')

      result = build(trigger)
      expect(result.phase).to eq(:opening)
      expect(result).to be_opening
      expect(result).not_to be_follow_up
    end

    it 'is follow_up when a public Marine reply exists earlier in the conversation' do
      add(:incoming, at: base + 1, content: 'hi')
      add(:outgoing, at: base + 2, sender: marine, content: 'earlier marine answer')
      trigger = add(:incoming, at: base + 5, content: 'follow-up question')

      result = build(trigger)
      expect(result.phase).to eq(:follow_up)
      expect(result).to be_follow_up
      expect(result).not_to be_opening
    end

    it 'stays opening despite a private Marine note, a human outgoing reply, and a later Marine reply' do
      add(:outgoing, at: base + 1, sender: marine, hidden: true, content: 'private marine note')
      add(:outgoing, at: base + 2, sender: agent, content: 'human agent reply')
      trigger = add(:incoming, at: base + 5, content: 'customer turn')
      add(:outgoing, at: base + 9, sender: marine, content: 'later marine reply') # AFTER the trigger

      expect(build(trigger).phase).to eq(:opening)
    end
  end
end
