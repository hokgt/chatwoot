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
      # outgoing/where/where/empty? chain resolves to true, and the takeover-precedence
      # query (Eligibility#human_takeover?, which calls `any?` on the same relation) is false.
      allow(messages).to receive(:outgoing).and_return(messages)
      allow(messages).to receive(:where).and_return(messages)
      allow(messages).to receive(:empty?).and_return(true)
      allow(messages).to receive(:any?).and_return(false)
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

    # A public outgoing reply from a human User agent — the classic takeover signal.
    def outgoing_user_reply
      create(:message, conversation: conversation, account: account, inbox: inbox,
                       message_type: :outgoing, private: false, sender: create(:user, account: account, role: :agent))
    end

    # A public outgoing native-app human reply: sender is the Contact (NOT sender_type User),
    # carrying content_attributes external_echo == true. This is the exact defect signal — a
    # human takeover the User-only scheduling check does not see.
    def outgoing_external_echo
      create(:message, conversation: conversation, account: account, inbox: inbox,
                       message_type: :outgoing, private: false, sender: contact,
                       content_attributes: { 'external_echo' => true })
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

    # Req 2 — public outgoing User reply + lapsed window: marker STAYS active, no reset, no job.
    it 'keeps an explicit human (User) takeover blocking after the window lapses: marker stays active, no schedule' do
      outgoing_user_reply
      message = incoming_at(anchor + 50.hours)
      expect(Marine::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      expect(described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)).to be(false)
      expect(marker_active?).to be(true)
    end

    # Req 1 — native-app human reply (external_echo == true, sender is NOT a User): marker STAYS
    # active, no job. This is the reported defect: takeover precedence was not enforced at reset.
    it 'keeps the marker active and schedules nothing when a native-app human reply (external_echo) exists after the window lapses' do
      outgoing_external_echo
      message = incoming_at(anchor + 50.hours)
      expect(Marine::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)

      expect(marker_active?).to be(true)
    end

    # Req 3 — passive assignee/team assignment WITHOUT a human reply is not a takeover: the marker
    # resets and exactly one response schedules, so assignment never permanently blocks re-entry.
    it 'treats passive assignee/team assignment (no human reply) as NOT a takeover: resets and schedules once after the window lapses' do
      conversation.update!(assignee: create(:user, account: account, role: :agent), team: create(:team, account: account))
      message = incoming_at(anchor + 50.hours)
      expect(Marine::Conversation::ResponseBuilderJob).to receive(:perform_later).with(conversation, assistant, message.id).once

      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)

      expect(marker_active?).to be(false)
    end

    # Req 8 — exact 24h boundary is lapsed (arrival >= anchor + window).
    it 'treats the exact 24h boundary as lapsed: resets and schedules' do
      message = incoming_at(anchor + 24.hours)
      expect(Marine::Conversation::ResponseBuilderJob).to receive(:perform_later).with(conversation, assistant, message.id).once

      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)

      expect(marker_active?).to be(false)
    end

    # Req 8 — one second before the boundary is still inside the window (strict `<` open test).
    it 'treats one second before the 24h boundary as still inside the window: marker stays, no schedule' do
      message = incoming_at(anchor + 24.hours - 1.second)
      expect(Marine::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)

      expect(marker_active?).to be(true)
    end

    # Req 4 — rolling inbounds: each new inbound (re)anchors the window. I1 inside I0's window keeps
    # the marker; I1b is >24h after I0 but only 10h after I1, so anchored on the ADVANCED anchor it
    # is still inside the window and the marker stays.
    it 'advances the window anchor across rolling inbounds still inside the fresh window (marker stays, no schedule)' do
      expect(Marine::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      i1 = incoming_at(anchor + 20.hours) # inside I0's 24h window
      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: i1)
      expect(marker_active?).to be(true)

      i1b = incoming_at(anchor + 30.hours) # >24h after I0, only 10h after I1 -> inside the advanced window
      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: i1b)
      expect(marker_active?).to be(true)
    end

    # Req 4 — once the newest inbound is a full window past the IMMEDIATELY-preceding inbound (the
    # advanced anchor), it resets and schedules exactly once.
    it 'resets and schedules once the newest inbound is a full window past the advanced anchor' do
      incoming_at(anchor + 20.hours)
      incoming_at(anchor + 30.hours)
      i2 = incoming_at(anchor + 54.hours) # 24h after the anchor+30h turn
      expect(Marine::Conversation::ResponseBuilderJob).to receive(:perform_later).with(conversation, assistant, i2.id).once

      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: i2)

      expect(marker_active?).to be(false)
    end

    # Req 5 — duplicate delivery of the SAME lapsed inbound is idempotent for the handoff marker:
    # the first turn resets it; a replay finds it already cleared and re-mutates nothing.
    it 'is idempotent across a duplicate delivery of the same lapsed inbound: the handoff marker is mutated at most once' do
      message = incoming_at(anchor + 50.hours)
      allow(Marine::Conversation::ResponseBuilderJob).to receive(:perform_later)

      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)
      expect(marker_active?).to be(false)
      cleared_attributes = conversation.reload.additional_attributes

      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)

      expect(conversation.reload.additional_attributes).to eq(cleared_attributes)
      expect(marker_active?).to be(false)
    end

    # Req 6 — after a post-window reset, replaying the real ResponseBuilderJob for the same trigger
    # message goes through the real ProcessingClaim path: at most one Marine reply and one completed
    # claim, no matter how many times the job runs.
    it 'runs the post-window ResponseBuilderJob replay through the real ProcessingClaim path with at most one reply and one completion' do
      message = incoming_at(anchor + 50.hours)
      allow(Marine::Conversation::ResponseBuilderJob).to receive(:perform_later)
      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)
      expect(marker_active?).to be(false)

      chat = instance_double(Marine::Llm::AssistantChatService,
                             generate_response: { 'response' => 'How can I help?', 'source_type' => 'manual' })
      allow(Marine::Llm::AssistantChatService).to receive(:new).and_return(chat)

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, message.id)
      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, message.id)

      expect(conversation.reload.messages.outgoing.where(sender_type: 'Marine::Assistant').count).to eq(1)
      claim = Marine::Conversation::ProcessingClaim.new(message: message.reload).current
      expect(claim['status']).to eq('completed')
    end

    # Req 7 — the core private messaging_window is unavailable/raises: HandoffWindow fails closed
    # (treats the window as not expired), so the marker stays terminal and nothing is scheduled.
    it 'fails closed when the core messaging window computation raises: marker stays active, no schedule' do
      allow_any_instance_of(Conversations::MessageWindowService).to receive(:messaging_window).and_raise(StandardError.new('boom')) # rubocop:disable RSpec/AnyInstance
      message = incoming_at(anchor + 50.hours)
      expect(Marine::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message)

      expect(marker_active?).to be(true)
    end

    # Req 9 — no timeout-triggered output. Window expiry ALONE (no inbound turn, hence no hook
    # invocation) resets nothing and schedules nothing, even far past the window.
    it 'emits nothing on window expiry alone: with no inbound turn the marker stays active and no job is scheduled' do
      expect(Marine::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      travel_to(anchor + 100.hours) do
        expect(marker_active?).to be(true)
      end
    end

    it 'creates no message or outbound content while clearing the lapsed marker' do
      message = incoming_at(anchor + 50.hours)
      allow(Marine::Conversation::ResponseBuilderJob).to receive(:perform_later)

      expect { described_class.claim_message_templates!(conversation: conversation, inbox: inbox, message: message) }
        .not_to(change { conversation.reload.messages.outgoing.count })
    end
  end

  # Req 9 (structural) — the ONLY code path that clears a handoff marker is the inbound-driven
  # hook. No timer/scheduler/job in the battery invokes HandoffStateStore#reset!, so window expiry
  # can never emit output on its own. Proven by source inspection so a future timer caller fails here.
  describe 'handoff reset is inbound-only (no timer caller)' do
    it 'invokes HandoffStateStore#reset! from the inbound hook alone' do
      app_root = Rails.root.join('custom/wijaya/batteries/marine_ai/app')
      callers = Dir.glob(app_root.join('**/*.rb')).select { |file| File.read(file).match?(/\.reset!/) }
      relative = callers.map { |file| Pathname.new(file).relative_path_from(Rails.root).to_s }

      expect(relative).to contain_exactly('custom/wijaya/batteries/marine_ai/app/services/wijaya/marine/hooks.rb')
    end
  end
end
