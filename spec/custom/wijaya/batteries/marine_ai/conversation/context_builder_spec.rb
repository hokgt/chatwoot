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

    it 'stays follow_up regardless of elapsed time or a resolve/reopen since the earlier Marine reply' do
      # Phase depends ONLY on the existence of an earlier public Marine reply — never on
      # elapsed time, inactivity, or conversation status. A months-long gap and a
      # resolve/reopen must NOT re-enable an opening greeting.
      add(:outgoing, at: base, sender: marine, content: 'earlier marine answer')
      conversation.update!(status: :resolved)
      conversation.update!(status: :open)
      trigger = add(:incoming, at: base + 90.days, content: 'much later customer turn')

      # Web widget has NO messaging-window policy, so the new-interaction window (D1) never engages
      # here — this is the fail-closed, window-agnostic path and stays follow_up despite the gap.
      expect(build(trigger).phase).to eq(:follow_up)
    end
  end

  # D1 — new native messaging window awareness. On a channel WITH an authoritative messaging
  # window (WhatsApp 24h), a trigger that opens a FRESH window is an opening/new interaction and
  # excludes ALL pre-window history (an aged unresolved topic can never be revived); a within-window
  # turn retains full context and its existing phase. Duration comes from the authoritative
  # Conversations::MessageWindowService, reused exactly as Marine::Circuit::HandoffWindow does.
  describe 'new native messaging window (D1)' do
    # WhatsApp inbox => authoritative 24h messaging window.
    let(:wa_channel) { create(:channel_whatsapp, sync_templates: false, validate_provider_config: false) }
    let(:wa_inbox) { wa_channel.inbox }
    let(:wa_account) { wa_inbox.account }
    let(:wa_conversation) { create(:conversation, account: wa_account, inbox: wa_inbox) }
    let(:wa_marine) { create(:marine_assistant, account: wa_account) }
    let(:wa_contact) { create(:contact, account: wa_account) }
    let(:win_base) { Time.zone.parse('2026-08-21T08:00:00Z') }

    def wadd(type, at:, content: 'sample text', hidden: false, sender: nil)
      create(:message, conversation: wa_conversation, account: wa_account, inbox: wa_inbox,
                       message_type: type, content: content, private: hidden,
                       sender: sender || (type == :incoming ? wa_contact : nil), created_at: at)
    end

    def wbuild(trigger)
      described_class.new(conversation: wa_conversation, trigger_message: trigger).build
    end

    it 'classifies a fresh-window trigger as opening and excludes ALL pre-window history (aged topic not revived)' do
      wadd(:incoming, at: win_base, content: 'how much is shipping to my port?') # aged unresolved topic
      wadd(:outgoing, at: win_base + 1.minute, sender: wa_marine, content: 'earlier marine reply')
      trigger = wadd(:incoming, at: win_base + 24.hours, content: 'hi') # opens a fresh 24h window

      result = wbuild(trigger)
      expect(result.phase).to eq(:opening)
      expect(result).to be_opening
      expect(result.history).to eq([])
      expect(result.trigger).to eq('hi')
    end

    it 'retains full context and stays follow_up for a within-window genuine follow-up' do
      wadd(:incoming, at: win_base, content: 'do you have impellers?')
      wadd(:outgoing, at: win_base + 1.minute, sender: wa_marine, content: 'earlier marine reply')
      trigger = wadd(:incoming, at: win_base + 1.hour, content: 'what about the price?') # same window

      result = wbuild(trigger)
      expect(result.phase).to eq(:follow_up)
      expect(result.history.map { |h| h[:content] }).to eq(['do you have impellers?', 'earlier marine reply'])
    end

    it 'treats exactly the window boundary as a fresh window (mirrors the native strict-< open test)' do
      wadd(:incoming, at: win_base, content: 'aged topic')
      trigger = wadd(:incoming, at: win_base + 24.hours, content: 'hi')

      result = wbuild(trigger)
      expect(result.phase).to eq(:opening)
      expect(result.history).to eq([])
    end

    it 'stays within-window one second before the boundary (retains history, not a new interaction)' do
      wadd(:incoming, at: win_base, content: 'aged topic')
      trigger = wadd(:incoming, at: win_base + 24.hours - 1.second, content: 'still same window')

      expect(wbuild(trigger).history.map { |h| h[:content] }).to eq(['aged topic'])
    end

    it 'fails closed (no new window) when there is no prior inbound to anchor on' do
      wadd(:outgoing, at: win_base, sender: wa_marine, content: 'proactive marine note')
      trigger = wadd(:incoming, at: win_base + 90.days, content: 'first customer turn')

      result = wbuild(trigger)
      # No prior INBOUND anchor -> window-agnostic behavior: an earlier public Marine reply exists,
      # so this is a follow-up and the prior outgoing is retained (never excluded as "pre-window").
      expect(result.phase).to eq(:follow_up)
      expect(result.history.map { |h| h[:content] }).to eq(['proactive marine note'])
    end
  end
end
