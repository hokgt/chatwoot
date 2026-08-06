# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Charge::ResponseGenerator do
  let(:assistant) { double('assistant', name: 'Marine Bot') }
  let(:knowledge_base) { instance_double(Marine::Cell::KnowledgeBaseService) }
  let(:generator) { described_class.new(assistant: assistant) }

  before do
    allow(Marine::Cell::KnowledgeBaseService).to receive(:new).with(assistant: assistant).and_return(knowledge_base)
  end

  # Keep translation a no-op by default so the commit 2 assertions stay stable.
  def stub_no_translation
    allow(Marine::Llm::TranslateQueryService).to receive(:new).and_return(
      double(call: { text: nil, source_language: 'en', translated: false, error: nil })
    )
    allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(
      double(call: { text: nil, source_language: 'en', target_language: 'en', translated: false, error: nil })
    )
  end

  it 'returns a reply payload with confidence and citation metadata on an exact match' do
    stub_no_translation
    response = Marine::AssistantResponse.new(id: 9, question: 'Hi', answer: 'Hello!')
    result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 1.0)
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'Hi')

    expect(payload).to include(
      'response' => 'Hello!',
      'action' => 'reply',
      'agent_name' => 'Marine Bot',
      'marine_cell_response_id' => 9,
      'confidence' => 1.0,
      'source_type' => 'manual',
      'response_ids' => [9],
      'document_ids' => [],
      'fallback_reason' => nil
    )
    expect(payload['citations']).to be_an(Array)
  end

  it 'synthesizes a RAG answer for a non-exact match when the LLM is configured' do
    stub_no_translation
    allow(assistant).to receive(:config).and_return({ 'instructions' => 'You are Marine.' })
    response = Marine::AssistantResponse.new(id: 7, question: 'Apa itu MOQ?', answer: 'MOQ is the minimum order quantity.')
    result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 0.5)
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    llm = double(configured?: true)
    captured_system = nil
    allow(llm).to receive(:chat) do |args|
      captured_system = args[:system]
      { ok: true, message: 'Textilindo is a textile manufacturer.', error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)

    payload = generator.generate(additional_message: 'Apa itu Textilindo?')

    expect(captured_system).to include('Never invent or fabricate information.')
    expect(payload).to include(
      'response' => 'Textilindo is a textile manufacturer.',
      'action' => 'reply',
      'source_type' => 'llm_rag',
      'fallback_reason' => nil,
      'confidence' => 0.5,
      'response_ids' => [7]
    )
  end

  it 'returns the raw FAQ answer for a non-exact match when the LLM is unconfigured' do
    stub_no_translation
    stub_llm_unconfigured
    response = Marine::AssistantResponse.new(id: 7, question: 'Apa itu MOQ?', answer: 'MOQ is the minimum order quantity.')
    result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 0.5)
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'Apa itu Textilindo?')

    expect(payload).to include(
      'response' => 'MOQ is the minimum order quantity.',
      'source_type' => 'manual',
      'confidence' => 0.5
    )
  end

  # Keep the LLM fallback out of the way by default so handoff assertions stay stable.
  def stub_llm_unconfigured
    allow(Marine::Llm::BaseService).to receive(:new).and_return(double(configured?: false))
  end

  it 'hands off using the low-confidence payload when there is no confident match' do
    stub_no_translation
    stub_llm_unconfigured
    result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'unknown')

    expect(payload).to include(
      'response' => 'conversation_handoff',
      'action' => 'handoff',
      'action_reason' => 'no_confident_cell_match'
    )
  end

  it 'uses RAG-grounded LLM fallback when retrieval fails and LLM is configured' do
    stub_no_translation
    llm = double(configured?: true)
    allow(llm).to receive(:chat).and_return({ ok: true, message: 'Halo! Selamat datang...', error: nil })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    allow(assistant).to receive(:config).and_return({ 'instructions' => 'You are Marine.' })
    result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'haloo')

    expect(payload).to include(
      'response' => 'Halo! Selamat datang...',
      'action' => 'reply',
      'agent_name' => 'Marine Bot',
      'source_type' => 'llm_rag',
      'fallback_reason' => 'no_confident_cell_match'
    )
  end

  it 'grounds the LLM fallback with approved Knowledge Base content' do
    stub_no_translation
    kb_entry = Marine::AssistantResponse.new(question: 'Textilindo Contact', answer: 'Office: Jl. Real Address 123, Bandung.')
    docs_relation = double('docs', limit: [kb_entry])
    faqs_relation = double('faqs', limit: [])
    approved = double('approved')
    allow(approved).to receive(:where).with(no_args).and_return(double('where_chain', not: docs_relation))
    allow(approved).to receive(:where).with(documentable_type: nil).and_return(faqs_relation)
    responses_relation = double('responses', approved: approved)
    allow(assistant).to receive(:responses).and_return(responses_relation)
    allow(assistant).to receive(:config).and_return({ 'instructions' => 'You are Marine.' })

    llm = double(configured?: true)
    captured_system = nil
    allow(llm).to receive(:chat) do |args|
      captured_system = args[:system]
      { ok: true, message: 'Our office is at Jl. Real Address 123, Bandung.', error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'Di mana alamat kantor Textilindo?')

    expect(payload['source_type']).to eq('llm_rag')
    expect(captured_system).to include('Knowledge Base Context:')
    expect(captured_system).to include('Jl. Real Address 123, Bandung.')
    expect(captured_system).to include('Never invent or fabricate information.')
  end

  it 'falls back to handoff when LLM is configured but returns an error' do
    stub_no_translation
    llm = double(configured?: true)
    allow(llm).to receive(:chat).and_return({ ok: false, message: nil, error: 'API timeout' })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    allow(assistant).to receive(:config).and_return({ 'instructions' => 'You are Marine.' })
    result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'unknown')

    expect(payload).to include('action' => 'handoff', 'action_reason' => 'no_confident_cell_match')
  end

  it 'includes language/translation metadata without mutating citations' do
    stub_no_translation
    response = Marine::AssistantResponse.new(id: 9, question: 'Hi', answer: 'Hello!')
    result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 1.0)
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'Hi')

    expect(payload).to include(
      'detected_language' => 'en',
      'query_language' => 'en',
      'translation_applied' => false,
      'response_translation_applied' => false,
      'translated_query' => nil,
      'translation_error' => nil
    )
    expect(payload['citations']).to eq(result.citations)
  end

  it 'retrieves with the translated query and translates the answer back' do
    allow(Marine::Llm::TranslateQueryService).to receive(:new).and_return(
      double(call: { text: 'Where is my order', source_language: 'id', translated: true, error: nil })
    )
    allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(
      double(call: { text: 'Pesanan Anda dalam perjalanan', source_language: 'en', target_language: 'id', translated: true, error: nil })
    )
    response = Marine::AssistantResponse.new(id: 9, question: 'Where is my order', answer: 'Your order is on the way')
    result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 1.0)
    allow(knowledge_base).to receive(:retrieve).with('Where is my order', limit: 1).and_return(result)

    payload = generator.generate(additional_message: 'Pesanan saya di mana')

    expect(payload).to include(
      'response' => 'Pesanan Anda dalam perjalanan',
      'query_language' => 'id',
      'response_language' => 'id',
      'translated_query' => 'Where is my order',
      'translation_applied' => true,
      'response_translation_applied' => true
    )
  end

  it 'does not block retrieval or handoff when Marine LLM is unconfigured' do
    allow(Marine::Llm::Config).to receive(:configured?).and_return(false)
    result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
    allow(knowledge_base).to receive(:retrieve).with('unknown', limit: 1).and_return(result)

    payload = generator.generate(additional_message: 'unknown')

    expect(payload).to include('action' => 'handoff', 'action_reason' => 'no_confident_cell_match')
    expect(payload).to have_key('translation_applied')
  end

  describe 'business-time grounding and greeting normalization' do
    # WIB (Asia/Jakarta) is UTC+7; Rails runs UTC. We travel to UTC instants and let
    # ActiveSupport timezone conversion derive the local business hour deterministically.
    def capture_llm_system(message: 'Halo, ada yang bisa dibantu?')
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      captured = { system: nil }
      allow(llm).to receive(:chat) do |args|
        captured[:system] = args[:system]
        { ok: true, message: message, error: nil }
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      captured
    end

    def stub_llm_fallback_retrieval
      result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
      allow(knowledge_base).to receive(:retrieve).and_return(result)
    end

    before do
      stub_no_translation
      allow(assistant).to receive(:config).and_return({ 'instructions' => 'You are Marine.' })
    end

    it 'greets pagi at 09:37 WIB' do
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        captured = capture_llm_system
        stub_llm_fallback_retrieval
        generator.generate(additional_message: 'halo')
        expect(captured[:system]).to include('Selamat pagi').and include('Asia/Jakarta')
      end
    end

    it 'greets pagi at 10:56 WIB' do
      travel_to(Time.utc(2026, 7, 20, 3, 56)) do
        captured = capture_llm_system
        stub_llm_fallback_retrieval
        generator.generate(additional_message: 'halo')
        expect(captured[:system]).to include('Selamat pagi')
      end
    end

    it 'greets siang at the 11:00 WIB boundary' do
      travel_to(Time.utc(2026, 7, 20, 4, 0)) do
        captured = capture_llm_system
        stub_llm_fallback_retrieval
        generator.generate(additional_message: 'halo')
        expect(captured[:system]).to include('Selamat siang')
      end
    end

    it 'greets sore at the 15:00 WIB boundary' do
      travel_to(Time.utc(2026, 7, 20, 8, 0)) do
        captured = capture_llm_system
        stub_llm_fallback_retrieval
        generator.generate(additional_message: 'halo')
        expect(captured[:system]).to include('Selamat sore')
      end
    end

    it 'greets malam at the 18:00 WIB boundary' do
      travel_to(Time.utc(2026, 7, 20, 11, 0)) do
        captured = capture_llm_system
        stub_llm_fallback_retrieval
        generator.generate(additional_message: 'halo')
        expect(captured[:system]).to include('Selamat malam')
      end
    end

    it 'prefers the configured account reporting timezone over the WIB fallback' do
      account = instance_double(Account, reporting_timezone: 'Asia/Tokyo')
      conversation = instance_double(Conversation, account: account)
      scoped = described_class.new(assistant: assistant, conversation: conversation)
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).with(assistant: assistant).and_return(knowledge_base)

      # UTC 09:30 -> Jakarta 16:30 (sore) but Tokyo 18:30 (malam); precedence => malam.
      travel_to(Time.utc(2026, 7, 20, 9, 30)) do
        captured = capture_llm_system
        stub_llm_fallback_retrieval
        scoped.generate(additional_message: 'halo')
        expect(captured[:system]).to include('Selamat malam').and include('Asia/Tokyo')
      end
    end

    it 'falls back to Asia/Jakarta when the account timezone is blank' do
      account = instance_double(Account, reporting_timezone: '')
      conversation = instance_double(Conversation, account: account)
      scoped = described_class.new(assistant: assistant, conversation: conversation)
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).with(assistant: assistant).and_return(knowledge_base)

      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        captured = capture_llm_system
        stub_llm_fallback_retrieval
        scoped.generate(additional_message: 'halo')
        expect(captured[:system]).to include('Selamat pagi').and include('Asia/Jakarta')
      end
    end

    it 'sends the local-time prompt on the RAG synthesis path too' do
      response = Marine::AssistantResponse.new(id: 7, question: 'Apa itu MOQ?', answer: 'MOQ is the minimum order quantity.')
      result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 0.5)
      allow(knowledge_base).to receive(:retrieve).and_return(result)

      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        captured = capture_llm_system(message: 'Textilindo adalah produsen tekstil.')
        generator.generate(additional_message: 'Apa itu Textilindo?')
        expect(captured[:system]).to include('Selamat pagi')
      end
    end

    it 'normalizes an incorrect opening greeting from the LLM' do
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        capture_llm_system(message: 'Halo! Selamat sore, ada yang bisa dibantu?')
        stub_llm_fallback_retrieval
        payload = generator.generate(additional_message: 'halo')
        expect(payload['response']).to eq('Halo! Selamat pagi, ada yang bisa dibantu?')
      end
    end

    it 'overrides a stale historical Selamat sore on a morning response' do
      history = [
        { role: 'user', content: 'halo' },
        { role: 'assistant', content: 'Selamat sore! Ada yang bisa dibantu?' }
      ]
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        capture_llm_system(message: 'Selamat sore, terima kasih sudah menghubungi kami.')
        stub_llm_fallback_retrieval
        payload = generator.generate(additional_message: 'halo', message_history: history)
        expect(payload['response']).to start_with('Selamat pagi')
      end
    end

    it 'leaves non-opening greeting mentions untouched' do
      body = 'Kami tutup pukul lima. Untuk sapaan, ucapkan Selamat sore.'
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        capture_llm_system(message: body)
        stub_llm_fallback_retrieval
        payload = generator.generate(additional_message: 'halo')
        expect(payload['response']).to eq(body)
      end
    end

    it 'leaves an opening sentence that merely starts with unrelated prose untouched' do
      body = 'Kami mengucapkan Selamat sore kepada seluruh pelanggan setia kami.'
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        capture_llm_system(message: body)
        stub_llm_fallback_retrieval
        payload = generator.generate(additional_message: 'halo')
        expect(payload['response']).to eq(body)
      end
    end

    it 'does not treat an arbitrary two-word lead-in as an opening greeting' do
      body = 'Dengan hormat Selamat sore, kami informasikan jadwal pengiriman.'
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        capture_llm_system(message: body)
        stub_llm_fallback_retrieval
        payload = generator.generate(additional_message: 'halo')
        expect(payload['response']).to eq(body)
      end
    end

    it 'preserves title-case when swapping the opening greeting' do
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        capture_llm_system(message: 'Selamat Sore, ada yang bisa dibantu?')
        stub_llm_fallback_retrieval
        payload = generator.generate(additional_message: 'halo')
        expect(payload['response']).to eq('Selamat Pagi, ada yang bisa dibantu?')
      end
    end

    it 'preserves uppercase when swapping the opening greeting' do
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        capture_llm_system(message: 'SELAMAT SORE, ADA YANG BISA DIBANTU?')
        stub_llm_fallback_retrieval
        payload = generator.generate(additional_message: 'halo')
        expect(payload['response']).to eq('SELAMAT PAGI, ADA YANG BISA DIBANTU?')
      end
    end

    it 'leaves an exact FAQ response unchanged even if it contains a greeting' do
      response = Marine::AssistantResponse.new(id: 9, question: 'Hi', answer: 'Selamat sore! Ada yang bisa dibantu?')
      result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 1.0)
      allow(knowledge_base).to receive(:retrieve).and_return(result)

      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        payload = generator.generate(additional_message: 'Hi')
        expect(payload['response']).to eq('Selamat sore! Ada yang bisa dibantu?')
      end
    end
  end
end
