# frozen_string_literal: true

require 'rails_helper'

# Runner-level gating of the trusted-memory re-engagement path: only a trigger-bound turn
# that OPENS a fresh native messaging window (returning customer), with no exact-FAQ
# precedence and no active product flow, may reach the re-engagement composer — and any
# composer failure/nil keeps the unchanged generic path (never a handoff).
RSpec.describe Marine::Agent::Runner do
  let(:wa_channel) { create(:channel_whatsapp, sync_templates: false, validate_provider_config: false) }
  let(:wa_inbox) { wa_channel.inbox }
  let(:account) { wa_inbox.account }
  let(:assistant) { create(:marine_assistant, account: account, config: { 'feature_memory' => true, 'language' => 'id' }) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: wa_inbox, contact: contact) }
  let(:base) { Time.zone.parse('2026-10-13T02:00:00Z') }

  let(:generator) { double('generator') }
  let(:composer) { instance_double(Marine::Memory::Reengagement::Composer) }
  let(:kb) { double('knowledge_base') }
  let(:kb_result) { double('retrieval_result', fallback_reason: 'no_match', confidence: 0.0) }
  let(:orchestrator) { double('product_orchestrator') }
  let(:guard) { instance_double(Marine::Circuit::DomainBoundaryGuard, call: nil) }
  let(:selection) { double('selection', scenario: nil, source: 'legacy', reason: 'closed') }

  before do
    MarineInbox.create!(inbox: wa_inbox, marine_assistant: assistant)
    allow(Marine::Charge::ResponseGenerator).to receive(:new).and_return(generator)
    allow(generator).to receive(:generate) { |**kwargs|
      @generate_calls << kwargs
      generic_reply
    }
    @generate_calls = []
    allow(Marine::Circuit::DomainBoundaryGuard).to receive(:new).and_return(guard)
    allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(kb)
    allow(kb).to receive(:retrieve).and_return(kb_result)
    allow(Marine::Catalog::ProductQueryOrchestrator).to receive(:new).and_return(orchestrator)
    @orchestrator_calls = []
    allow(orchestrator).to receive(:process) { |**kwargs|
      @orchestrator_calls << kwargs
      { action: :not_product }
    }
    allow(Marine::Decision::CutoverScenarioSelector).to receive(:new)
      .and_return(instance_double(Marine::Decision::CutoverScenarioSelector, select: selection))
    allow(Marine::Memory::Reengagement::Composer).to receive(:new).and_return(composer)
    allow(composer).to receive(:compose).and_return(nil)
  end

  def generic_reply
    { 'response' => 'generic reply', 'action' => 'reply', 'agent_name' => assistant.name,
      'confidence' => 0.9, 'source_type' => 'manual' }
  end

  def msg(type, at:, content:, sender: nil)
    create(:message, conversation: conversation, account: account, inbox: wa_inbox,
                     message_type: type, content: content, private: false,
                     sender: sender || (type == :incoming ? contact : nil), created_at: at)
  end

  def trusted_note(content) # rubocop:disable Metrics/AbcSize -- one deliberate DB fixture factory for the trusted v2 memory note
    source = create(:conversation, account: account, inbox: wa_inbox, contact: contact)
    start_message = create(:message, conversation: source, account: account, inbox: wa_inbox, sender: contact,
                                     message_type: :incoming, private: false, content: 'source customer turn',
                                     created_at: base - 2.days)
    end_message = create(:message, conversation: source, account: account, inbox: wa_inbox, sender: assistant,
                                   message_type: :outgoing, private: false, content: 'source assistant reply',
                                   created_at: base - 2.days + 1.minute)
    marker = Marine::Memory::Marker.build_v2(
      trigger_source: 'idle_timeout', conversation: source,
      start_id: start_message.id, end_id: end_message.id,
      fingerprint: Digest::SHA256.hexdigest("src-#{start_message.id}-#{end_message.id}")
    )
    create(:message, conversation: source, account: account, inbox: wa_inbox, sender: assistant,
                     message_type: :outgoing, private: true, content: content,
                     additional_attributes: { Marine::Memory::Marker::KEY => marker })
  end

  def reengagement_result
    Marine::Memory::Reengagement::Composer::Result.new(
      text: 'Halo! Kemarin kita pernah membahas seragam serikat. Mau lanjut hari ini? Ada kebutuhan lain?',
      language: 'id'
    )
  end

  it 're-engages a returning customer on a fresh-window pure greeting' do
    trusted_note('Customer menanyakan seragam serikat.')
    msg(:incoming, at: base, content: 'previous visit turn')
    msg(:outgoing, at: base + 1.minute, content: 'earlier marine reply', sender: assistant)
    trigger = msg(:incoming, at: base + 24.hours, content: 'selamat pagi')
    allow(composer).to receive(:compose).and_return(reengagement_result)

    payload = described_class.new(assistant: assistant, conversation: conversation, source: trigger).run

    expect(composer).to have_received(:compose)
      .with(conversation: conversation, trigger: 'selamat pagi', configured_language: 'id')
    expect(payload).to include(
      'response' => reengagement_result.text,
      'action' => 'reply',
      'agent_name' => assistant.name,
      'source_type' => 'marine_memory_reengagement',
      'orchestration_path' => 'memory_reengagement'
    )
    expect(payload).not_to include('product_plan')
    expect(generator).not_to have_received(:generate)

    # The remembered topic NEVER enters product intent: the orchestrator received the
    # canonical fresh-window history (empty) and the bare trigger — no note content anywhere.
    expect(@orchestrator_calls.size).to eq(1)
    expect(@orchestrator_calls.first[:text]).to eq('selamat pagi')
    expect(@orchestrator_calls.first[:context]).to eq([])
  end

  it 'does not re-engage again on a repeated greeting inside the same interaction window' do
    msg(:incoming, at: base, content: 'previous visit turn')
    msg(:outgoing, at: base + 1.minute, content: 'earlier marine reply', sender: assistant)
    trigger = msg(:incoming, at: base + 1.hour, content: 'selamat pagi lagi')

    payload = described_class.new(assistant: assistant, conversation: conversation, source: trigger).run

    expect(composer).not_to have_received(:compose)
    expect(payload['orchestration_path']).to eq('retrieval')
    expect(generator).to have_received(:generate)
    expect(@generate_calls.first[:opening]).to be(false)
  end

  it 'can re-engage again in a later fresh interaction window' do
    trusted_note('Customer menanyakan seragam serikat.')
    msg(:incoming, at: base, content: 'first visit')
    msg(:outgoing, at: base + 1.minute, content: 'earlier marine reply', sender: assistant)
    first_visit_trigger = msg(:incoming, at: base + 24.hours, content: 'selamat pagi')
    described_class.new(assistant: assistant, conversation: conversation, source: first_visit_trigger).run

    # A LATER fresh window (24h after the previous inbound) is eligible again.
    second_trigger = msg(:incoming, at: base + 48.hours, content: 'selamat siang')
    allow(composer).to receive(:compose).and_return(reengagement_result)
    payload = described_class.new(assistant: assistant, conversation: conversation, source: second_trigger).run

    expect(composer).to have_received(:compose).with(conversation: conversation, trigger: 'selamat siang',
                                                     configured_language: 'id')
    expect(payload['orchestration_path']).to eq('memory_reengagement')
  end

  it 'does not re-engage while a product flow is still active' do
    conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'product_flow_v1' => {
                           'version' => 4, 'flow_id' => 'live', 'status' => 'active', 'expires_at' => 1.year.from_now.iso8601,
                           'validated_family' => 'SYN-FAMILY', 'current_intent' => 'catalog'
                         } } })
    trusted_note('Customer menanyakan seragam serikat.')
    msg(:incoming, at: base, content: 'previous visit turn')
    trigger = msg(:incoming, at: base + 24.hours, content: 'selamat pagi')

    described_class.new(assistant: assistant, conversation: conversation, source: trigger).run

    expect(composer).not_to have_received(:compose)
    expect(generator).to have_received(:generate)
  end

  it 'never preempts an exact approved-FAQ match with re-engagement' do
    trusted_note('Customer menanyakan seragam serikat.')
    allow(kb).to receive(:retrieve).and_return(
      double('exact_result', fallback_reason: nil, confidence: 1.0, source_type: 'manual')
    )
    msg(:incoming, at: base, content: 'previous visit turn')
    trigger = msg(:incoming, at: base + 24.hours, content: 'selamat pagi')

    described_class.new(assistant: assistant, conversation: conversation, source: trigger).run

    expect(composer).not_to have_received(:compose)
    expect(orchestrator).not_to have_received(:process)
    expect(@generate_calls.first[:exact_knowledge_result].fallback_reason).to be_nil
  end

  it 'keeps the generic greeting/help path (no handoff) when re-engagement declines or fails' do
    trusted_note('Customer menanyakan seragam serikat.')
    msg(:incoming, at: base, content: 'previous visit turn')
    trigger = msg(:incoming, at: base + 24.hours, content: 'selamat pagi')
    allow(composer).to receive(:compose).and_return(nil)
    payload = described_class.new(assistant: assistant, conversation: conversation, source: trigger).run
    expect(payload['action']).to eq('reply')
    expect(payload['orchestration_path']).to eq('retrieval')

    allow(composer).to receive(:compose).and_raise(StandardError)
    payload = described_class.new(assistant: assistant, conversation: conversation, source: trigger).run
    expect(payload['action']).to eq('reply')
    expect(payload['response']).to eq('generic reply')
  end

  it 'keeps advisory memory from displacing the newest canonical context on genuine follow-ups' do
    trusted_note('Customer menanyakan seragam serikat.')
    msg(:incoming, at: base, content: 'previous visit turn')
    msg(:outgoing, at: base + 1.minute, content: 'earlier marine reply', sender: assistant)
    msg(:incoming, at: base + 30.minutes, content: 'saya butuh info terbaru')
    trigger = msg(:incoming, at: base + 40.minutes, content: 'terima kasih')

    described_class.new(assistant: assistant, conversation: conversation, source: trigger).run

    expect(composer).not_to have_received(:compose)
    history = @generate_calls.first[:message_history]
    # Newest canonical public context stays LAST; the advisory envelope only leads.
    expect(history.last).to eq({ role: 'user', content: 'saya butuh info terbaru' })
    expect(history.first[:role]).to eq('assistant')
    expect(history.first[:content]).to include('ADVISORY HISTORICAL MEMORY')
  end
end
