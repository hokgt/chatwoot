# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Memory::ContactNotesService do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) do
    create(:marine_assistant, account: account,
                              config: { 'feature_memory' => true, 'memory_idle_timeout_hours' => 2 })
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :open) }
  let(:base_service) { instance_double(Marine::Llm::BaseService, configured?: true) }
  let(:valid_json) { { has_durable_memory: true, summary: 'Pelanggan lebih suka dihubungi melalui email.' }.to_json }
  let(:valid_verdict) { { is_indonesian: true, is_durable: true, is_generic: false, has_dynamic_product_facts: false }.to_json }

  before do
    MarineInbox.create!(inbox: inbox, marine_assistant: assistant)
    allow(Marine::Llm::BaseService).to receive(:new).with(account: account).and_return(base_service)
    completion_count = 0
    allow(base_service).to receive(:complete) do
      completion_count += 1
      { ok: true, message: completion_count.odd? ? valid_json : valid_verdict, error: nil }
    end
  end

  def incoming(content, at: 3.hours.ago)
    create(:message, conversation: conversation, account: account, inbox: inbox, sender: contact,
                     message_type: :incoming, private: false, content: content, created_at: at)
  end

  def outgoing(content, at: 3.hours.ago)
    create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                     message_type: :outgoing, private: false, content: content, created_at: at)
  end

  # rubocop:disable Metrics/ParameterLists -- Test setup helper models the complete signal contract.
  def signal_turn(status:, requested: [], delivered: [], at: 3.hours.ago, reply: true, evidence: [])
    trigger = incoming("turn-#{status}-#{SecureRandom.hex(3)}", at: at)
    claim = Marine::Conversation::ProcessingClaim.new(message: trigger)
    owner = claim.acquire!
    public_reply = outgoing("reply-#{status}", at: at) if reply
    claim.complete!(claim_id: owner.claim['claim_id'])
    Marine::Memory::Signal.write!(
      message: trigger, status: status, requested_capabilities: requested,
      delivered_capabilities: delivered, evidence_versions: evidence,
      public_reply_message_id: public_reply&.id
    )
    trigger
  end
  # rubocop:enable Metrics/ParameterLists

  def complete_turn(capability: 'price', at: 3.hours.ago)
    signal_turn(status: 'complete', requested: [capability], delivered: [capability], at: at,
                evidence: ['marine_evidence_v2'])
  end

  def notes
    conversation.messages.where(private: true, message_type: :outgoing)
  end

  def service
    described_class.new(assistant: assistant, conversation: conversation)
  end

  it 'creates one private v2 Indonesian note after the configured idle timeout without mutating status or assignee' do
    complete_turn
    before_state = conversation.reload.attributes.slice('status', 'assignee_id')

    expect { service.generate_and_store(trigger_source: 'idle_timeout') }.to change(notes, :count).by(1)

    note = notes.last
    marker = note.additional_attributes.fetch(Marine::Memory::Marker::KEY)
    expect(note).to have_attributes(private: true, content: include('Pelanggan lebih suka'))
    expect(marker).to include('version' => 2, 'trigger_source' => 'idle_timeout',
                              'memory_signal_version' => 'marine_memory_signal_v1')
    expect(conversation.reload.attributes.slice('status', 'assignee_id')).to eq(before_state)
    expect(contact.notes).to be_empty
  end

  %i[open pending resolved].each do |status|
    it "treats #{status} as an equivalent eligible state rather than a trigger" do
      conversation.update!(status: status)
      complete_turn
      expect(service.generate_and_store(trigger_source: 'cron_fallback')).to include(ok: true, created: 1)
    end
  end

  it 'skips snoozed conversations and recent public activity' do
    complete_turn
    conversation.update!(status: :snoozed)
    expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'conversation_ineligible_status')

    conversation.update!(status: :open)
    outgoing('recent', at: 5.minutes.ago)
    expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'not_idle')
    expect(notes).to be_empty
  end

  it 'allows complete then neutral, blocks complete then blocking, and allows a later complete' do
    complete_turn
    signal_turn(status: 'neutral', at: 3.hours.ago)
    expect(service).to be_eligible

    signal_turn(status: 'blocking', requested: ['stock'], at: 3.hours.ago, reply: false)
    expect(service).not_to be_eligible

    complete_turn(capability: 'stock')
    expect(service).to be_eligible
  end

  it 'blocks unmatched incoming messages and active unresolved flow state' do
    complete_turn
    incoming('unfinalized', at: 3.hours.ago)
    expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'unmatched_incoming')

    unmatched = conversation.messages.incoming.last
    unmatched.destroy!
    conversation.reload
    Marine::Catalog::ProductFlowStateStore.new(conversation: conversation).start!(
      'validated_family' => 'SYN-FAMILY', 'requested_intents' => ['price']
    )
    expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'unresolved_clarification')
  end

  it 'drops a generated result when public activity arrives during generation beyond the snapshot cap' do
    stub_const("#{described_class}::MAX_SOURCE_MESSAGES", 2)
    complete_turn
    completion_count = 0
    allow(base_service).to receive(:complete) do
      completion_count += 1
      if completion_count == 1
        outgoing('arrived during generation', at: Time.current)
        { ok: true, message: valid_json, error: nil }
      else
        { ok: true, message: valid_verdict, error: nil }
      end
    end

    expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'stale_snapshot')
    expect(notes).to be_empty
  end

  it 'deduplicates an exact range across idle/cron interleaving and a later-day cron replay' do
    complete_turn
    competitor = described_class.new(assistant: assistant, conversation: conversation)
    outer = described_class.new(assistant: assistant, conversation: conversation)
    allow(outer).to receive(:summarize) do |_snapshot|
      competitor.generate_and_store(trigger_source: 'cron_fallback')
      'Pelanggan lebih suka dihubungi melalui email.'
    end

    outer.generate_and_store(trigger_source: 'idle_timeout')
    travel 1.day do
      described_class.new(assistant: assistant, conversation: conversation)
                     .generate_and_store(trigger_source: 'cron_fallback')
    end
    expect(notes.count).to eq(1)
  end

  it 'allows two distinct eligible ranges on the same day' do
    complete_turn
    expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 1)
    complete_turn(capability: 'stock', at: 2.hours.ago - 1.minute)
    expect(described_class.new(assistant: assistant, conversation: conversation)
                          .generate_and_store(trigger_source: 'cron_fallback')).to include(created: 1)
    expect(notes.count).to eq(2)
  end

  it 'keeps a trusted v1 watermark and does not resummarize its range' do
    trigger = incoming('legacy range', at: 3.hours.ago)
    reply = outgoing('legacy reply', at: 3.hours.ago)
    snapshot = service.send(:public_snapshot_after, 0)
    marker = Marine::Memory::Marker.build(
      state: 'checkpoint', conversation: conversation, start_id: trigger.id, end_id: reply.id,
      fingerprint: service.send(:fingerprint, snapshot)
    )
    conversation.messages.create!(account: account, inbox: inbox, sender: assistant, message_type: :outgoing,
                                  private: true, content: 'Marine memory: catatan lama',
                                  additional_attributes: { Marine::Memory::Marker::KEY => marker })

    expect(base_service).not_to receive(:complete)
    expect(service.generate_and_store(trigger_source: 'cron_fallback')).to include(created: 0, error: 'no_new_incoming')
    expect(notes.count).to eq(1)
  end

  {
    'no durable memory' => { has_durable_memory: false, summary: nil }.to_json,
    'malformed JSON' => 'not-json',
    'prose around JSON' => 'Result: {"has_durable_memory":false,"summary":null}',
    'a fenced payload' => "```json\n{\"has_durable_memory\":false,\"summary\":null}\n```",
    'an extra key' => '{"has_durable_memory":true,"summary":"Pelanggan lebih suka dihubungi melalui email.","extra":1}',
    'a wrong boolean type' => '{"has_durable_memory":"true","summary":"Pelanggan lebih suka dihubungi melalui email."}',
    'a wrong summary type' => '{"has_durable_memory":true,"summary":["Pelanggan lebih suka email"]}',
    'a non-object payload' => '[true,"Pelanggan lebih suka dihubungi melalui email."]',
    'an invalid encoding' => -> { "{\"has_durable_memory\":true,\"summary\":\"pelanggan\"}\xFF".dup.force_encoding(Encoding::UTF_8) },
    'a non-string validator input' => Object.new,
    'an oversized payload' => -> { %({"has_durable_memory":true,"summary":"#{'a' * 5000}"}) }
  }.each do |label, payload|
    it "writes no note and does not call the judge for generator #{label}" do
      complete_turn
      message = payload.respond_to?(:call) ? payload.call : payload
      expect(base_service).to receive(:complete).once.and_return(ok: true, message: message, error: nil)

      expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'no_durable_memory')
      expect(notes).to be_empty
    end
  end

  it 'rejects an accepting last-value generator duplicate without calling the judge' do
    complete_turn
    generator = '{"has_durable_memory":false,"has_durable_memory":true,"summary":"Pelanggan lebih suka dihubungi melalui email."}'
    expect(base_service).to receive(:complete).once.and_return(ok: true, message: generator, error: nil)

    expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'no_durable_memory')
    expect(notes).to be_empty
  end

  {
    'English containing email' => ['Customer prefers email communication.',
                                   { is_indonesian: false, is_durable: true, is_generic: false, has_dynamic_product_facts: false }],
    'mixed language with shared markers' => ['Customer prefers email dan nomor telepon.',
                                             { is_indonesian: false, is_durable: true, is_generic: false, has_dynamic_product_facts: false }],
    'a generic note' => ['Catatan umum pelanggan telah dibuat.',
                         { is_indonesian: true, is_durable: true, is_generic: true, has_dynamic_product_facts: false }],
    'a current price claim' => ['Pelanggan meminta harga saat ini sebesar seratus ribu rupiah.',
                                { is_indonesian: true, is_durable: true, is_generic: false, has_dynamic_product_facts: true }],
    'a current stock claim' => ['Pelanggan telah memilih produk yang stoknya tersedia sekarang.',
                                { is_indonesian: true, is_durable: true, is_generic: false, has_dynamic_product_facts: true }],
    'a current quantity claim' => ['Pelanggan meminta jumlah saat ini sebanyak sepuluh unit.',
                                   { is_indonesian: true, is_durable: true, is_generic: false, has_dynamic_product_facts: true }],
    'a current location claim' => ['Pelanggan telah memilih barang di lokasi gudang utama.',
                                   { is_indonesian: true, is_durable: true, is_generic: false, has_dynamic_product_facts: true }]
  }.each do |label, (summary, verdict)|
    it "writes no note for #{label} by typed judge verdict" do
      complete_turn
      generator = { has_durable_memory: true, summary: summary }.to_json
      allow(base_service).to receive(:complete).and_return(
        { ok: true, message: generator, error: nil }, { ok: true, message: verdict.to_json, error: nil }
      )

      expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'no_durable_memory')
      expect(notes).to be_empty
    end
  end

  [
    'not-json',
    'Judge: {"is_indonesian":true,"is_durable":true,"is_generic":false,"has_dynamic_product_facts":false}',
    "```json\n{\"is_indonesian\":true,\"is_durable\":true,\"is_generic\":false,\"has_dynamic_product_facts\":false}\n```",
    '{"is_indonesian":true,"is_durable":true,"is_generic":false,"has_dynamic_product_facts":false,"extra":true}',
    '{"is_indonesian":"true","is_durable":true,"is_generic":false,"has_dynamic_product_facts":false}',
    lambda {
      "{\"is_indonesian\":true,\"is_durable\":true,\"is_generic\":false,\"has_dynamic_product_facts\":false}\xFF".dup.force_encoding(Encoding::UTF_8)
    },
    -> { %({"is_indonesian":true,"is_durable":true,"is_generic":false,"has_dynamic_product_facts":false,"padding":"#{'a' * 5000}"}) }
  ].each_with_index do |verdict, index|
    it "rejects strict malformed judge verdict #{index + 1} without writing a note" do
      complete_turn
      response = verdict.respond_to?(:call) ? verdict.call : verdict
      allow(base_service).to receive(:complete).and_return(
        { ok: true, message: valid_json, error: nil }, { ok: true, message: response, error: nil }
      )

      expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'no_durable_memory')
      expect(notes).to be_empty
    end
  end

  it 'rejects an accepting last-value judge duplicate without writing a note' do
    complete_turn
    judge = '{"is_indonesian":false,"is_indonesian":true,"is_durable":true,"is_generic":false,"has_dynamic_product_facts":false}'
    expect(base_service).to receive(:complete).twice.and_return(
      { ok: true, message: valid_json, error: nil }, { ok: true, message: judge, error: nil }
    )

    expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'no_durable_memory')
    expect(notes).to be_empty
  end

  it 'calls the generator before the judge with candidate JSON and writes no note on judge provider failure' do
    complete_turn
    expect(base_service).to receive(:complete).ordered do |prompt:, system:|
      expect(prompt).to include('Customer:', 'Assistant:')
      expect(system).to include('has_durable_memory')
      { ok: true, message: valid_json, error: nil }
    end
    expect(base_service).to receive(:complete).ordered do |prompt:, system:|
      expect(prompt).to eq(JSON.generate(candidate: 'Pelanggan lebih suka dihubungi melalui email.'))
      expect(system).to include('advisory validation judge only', 'not a business or product authority')
      { ok: false, message: nil, error: 'provider_error' }
    end

    expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'no_durable_memory')
    expect(notes).to be_empty
  end

  it 'writes no note and advances no watermark for provider failure' do
    complete_turn
    allow(base_service).to receive(:complete).and_return(ok: false, error: 'provider_error')

    expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 0, error: 'no_durable_memory')
    expect(notes).to be_empty
  end

  it 'excludes private/activity rows from both the transcript and public idle revision' do
    complete_turn
    create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                     message_type: :outgoing, private: true, content: 'PRIVATE SECRET', created_at: Time.current)
    create(:message, conversation: conversation, account: account, inbox: inbox,
                     message_type: :activity, private: false, content: 'ACTIVITY SECRET', created_at: Time.current)
    expect(base_service).to receive(:complete).ordered do |prompt:, system:|
      expect(prompt).not_to include('PRIVATE SECRET', 'ACTIVITY SECRET')
      expect(system).to include('strict JSON', 'Bahasa Indonesia', 'Never preserve current price, stock, quantity, or location')
      { ok: true, message: valid_json, error: nil }
    end
    expect(base_service).to receive(:complete).ordered.and_return(ok: true, message: valid_verdict, error: nil)

    expect(service.generate_and_store(trigger_source: 'idle_timeout')).to include(created: 1)
  end
end
