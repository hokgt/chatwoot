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

  # Phase 4 — context-aware grounded RAG interaction policy: the opening/follow-up signal
  # threaded from the canonical ContextBuilder gates the greeting, and the generated-RAG
  # interaction policy instructs the model generically (latest-first, relevant-history-only,
  # no-needless-repeat, concise, acknowledge-supplied, unsupported-but-closed-book).
  describe 'context-aware RAG interaction policy (Phase 4)' do
    before do
      stub_no_translation
      allow(assistant).to receive(:config).and_return({ 'instructions' => 'You are Marine.' })
    end

    def capture_llm(message: 'ok')
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
      allow(knowledge_base).to receive(:retrieve).and_return(
        Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
      )
    end

    it 'includes the generic interaction policy and preserves the closed-book/no-fabrication rules' do
      captured = capture_llm
      stub_llm_fallback_retrieval
      generator.generate(additional_message: 'halo')

      expect(captured[:system]).to include('Answer ONLY using the information in the Knowledge Base Context above.')
      expect(captured[:system]).to include('Never invent or fabricate information.')
      expect(captured[:system]).to include('Address the latest customer request first.')
      expect(captured[:system]).to include('only when they are relevant to the latest request')
      expect(captured[:system]).to include('do not unnecessarily repeat an answer you have already given')
      expect(captured[:system]).to include('Acknowledge relevant details the customer has already provided.')
      expect(captured[:system]).to include('Keep your reply concise.')
      expect(captured[:system]).to include('say so naturally while still relying only on the approved information above.')
    end

    it 'grounds the business-time greeting on an opening turn (opening: true)' do
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        captured = capture_llm
        stub_llm_fallback_retrieval
        generator.generate(additional_message: 'halo', opening: true)
        expect(captured[:system]).to include('Selamat pagi')
        expect(captured[:system]).to include('The correct Indonesian time-of-day greeting')
      end
    end

    it 'prohibits a new opening greeting on a follow-up turn (opening: false)' do
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        captured = capture_llm
        stub_llm_fallback_retrieval
        generator.generate(additional_message: 'follow-up question', opening: false)
        expect(captured[:system]).to include('Do NOT begin your reply with an opening greeting')
        expect(captured[:system]).not_to include('The correct Indonesian time-of-day greeting')
      end
    end

    it 'removes a recognized opening greeting from the LLM reply on a follow-up turn' do
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        capture_llm(message: 'Halo! Selamat sore, ada yang bisa dibantu?')
        stub_llm_fallback_retrieval
        payload = generator.generate(additional_message: 'follow-up question', opening: false)
        expect(payload['response']).to eq('Ada yang bisa dibantu?')
      end
    end

    it 'leaves later greeting mentions and unrelated prose untouched on a follow-up turn' do
      body = 'Kami tutup pukul lima. Untuk sapaan, ucapkan Selamat sore.'
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        capture_llm(message: body)
        stub_llm_fallback_retrieval
        payload = generator.generate(additional_message: 'follow-up question', opening: false)
        expect(payload['response']).to eq(body)
      end
    end

    it 'strips a standalone opening salutation and preserves the substantive text on a follow-up turn' do
      capture_llm(message: 'Halo, ada yang bisa dibantu?')
      stub_llm_fallback_retrieval
      payload = generator.generate(additional_message: 'follow-up question', opening: false)
      expect(payload['response']).to eq('Ada yang bisa dibantu?')
    end

    it 'strips a whitespace-prefixed standalone opening salutation and capitalizes the remainder on a follow-up turn' do
      capture_llm(message: '  Halo, ada yang bisa dibantu?')
      stub_llm_fallback_retrieval
      payload = generator.generate(additional_message: 'follow-up question', opening: false)
      expect(payload['response']).to eq('Ada yang bisa dibantu?')
    end

    it 'leaves an in-body salutation mention untouched on a follow-up turn' do
      body = 'Silakan sapa tim kami dengan halo kapan saja.'
      capture_llm(message: body)
      stub_llm_fallback_retrieval
      payload = generator.generate(additional_message: 'follow-up question', opening: false)
      expect(payload['response']).to eq(body)
    end

    it 'leaves a prefix word that merely starts with a salutation untouched on a follow-up turn' do
      body = 'History pesanan Anda sudah kami kirim.'
      capture_llm(message: body)
      stub_llm_fallback_retrieval
      payload = generator.generate(additional_message: 'follow-up question', opening: false)
      expect(payload['response']).to eq(body)
    end

    # Regression — a non-substantive follow-up (e.g. a bare greeting) reviving an earlier request. On
    # a follow-up turn the RAG generation is fed the full prior history; the old policy only told the
    # model to "Continue the conversation naturally", so a bare greeting could be answered by resuming
    # the earlier topic. The follow-up interaction policy must now forbid resurrecting an earlier
    # request/topic when the customer's latest message does not itself raise it. Generic and
    # data-driven — no product/phrase/language handling. The system prompt is the deterministic
    # artifact of that steering, so we assert it here (the real
    # generate -> rag_system_prompt -> GreetingContext#interaction_prompt path).
    it 'forbids resurrecting an earlier request/topic on a non-substantive follow-up turn' do
      captured = capture_llm
      stub_llm_fallback_retrieval
      generator.generate(additional_message: 'hello there', opening: false)

      expect(captured[:system]).to include('do NOT reintroduce, resume, or re-answer an earlier request or topic')
      expect(captured[:system]).to include("respond to the customer's latest message on its own terms")
      # Genuine follow-ups are still continued — the guard coexists with the continuation cue.
      expect(captured[:system]).to include('Continue the conversation naturally.')
    end

    it 'does not carry the topic-reset guard on an opening turn (no earlier topic to resurrect)' do
      travel_to(Time.utc(2026, 7, 20, 2, 37)) do
        captured = capture_llm
        stub_llm_fallback_retrieval
        generator.generate(additional_message: 'hello there', opening: true)

        expect(captured[:system]).not_to include('do NOT reintroduce, resume, or re-answer an earlier request or topic')
        expect(captured[:system]).to include('The correct Indonesian time-of-day greeting')
      end
    end
  end

  # Finding 2 — the follow-up greeting policy can strip a greeting-only LLM reply down to
  # blank. Enforcement runs BEFORE the payload is built and a blank result is treated as an
  # unusable LLM output, so each generated-RAG branch fails closed to its EXISTING fallback
  # (never a blank outgoing message): the no-match fallback branch hands off; the non-exact
  # synthesis branch returns the raw approved FAQ answer.
  describe 'fail-closed on blank follow-up enforcement (Finding 2)' do
    before do
      stub_no_translation
      allow(assistant).to receive(:config).and_return({ 'instructions' => 'You are Marine.' })
    end

    def stub_llm(message)
      llm = double(configured?: true)
      allow(llm).to receive(:chat).and_return({ ok: true, message: message, error: nil })
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    end

    it 'hands off when the follow-up policy strips the LLM fallback reply to blank' do
      stub_llm('Selamat sore!')
      allow(knowledge_base).to receive(:retrieve).and_return(
        Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
      )

      payload = generator.generate(additional_message: 'follow-up question', opening: false)

      expect(payload).to include('action' => 'handoff', 'action_reason' => 'no_confident_cell_match')
    end

    it 'returns the raw approved FAQ answer when the follow-up policy strips the RAG synthesis to blank' do
      stub_llm('Halo! Selamat pagi.')
      response = Marine::AssistantResponse.new(id: 7, question: 'Apa itu MOQ?', answer: 'MOQ is the minimum order quantity.')
      result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 0.5)
      allow(knowledge_base).to receive(:retrieve).and_return(result)

      payload = generator.generate(additional_message: 'follow-up question', opening: false)

      expect(payload).to include(
        'response' => 'MOQ is the minimum order quantity.',
        'source_type' => 'manual',
        'confidence' => 0.5
      )
    end

    it 'hands off when the follow-up policy strips a standalone-salutation-only LLM fallback reply to blank' do
      stub_llm('Halo!')
      allow(knowledge_base).to receive(:retrieve).and_return(
        Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
      )

      payload = generator.generate(additional_message: 'follow-up question', opening: false)

      expect(payload).to include('action' => 'handoff', 'action_reason' => 'no_confident_cell_match')
    end

    it 'hands off when the follow-up policy strips a whitespace-prefixed salutation-only LLM fallback reply to blank' do
      stub_llm('  Halo!')
      allow(knowledge_base).to receive(:retrieve).and_return(
        Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
      )

      payload = generator.generate(additional_message: 'follow-up question', opening: false)

      expect(payload).to include('action' => 'handoff', 'action_reason' => 'no_confident_cell_match')
    end

    it 'returns the raw approved FAQ answer when the follow-up policy strips a standalone-salutation-only RAG synthesis to blank' do
      stub_llm('Hai')
      response = Marine::AssistantResponse.new(id: 7, question: 'Apa itu MOQ?', answer: 'MOQ is the minimum order quantity.')
      result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 0.5)
      allow(knowledge_base).to receive(:retrieve).and_return(result)

      payload = generator.generate(additional_message: 'follow-up question', opening: false)

      expect(payload).to include(
        'response' => 'MOQ is the minimum order quantity.',
        'source_type' => 'manual',
        'confidence' => 0.5
      )
    end

    it 'still emits the normal llm_rag payload/metadata when the follow-up reply is non-blank' do
      stub_llm('Halo! Selamat pagi, ada yang bisa dibantu?')
      allow(knowledge_base).to receive(:retrieve).and_return(
        Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
      )

      payload = generator.generate(additional_message: 'follow-up question', opening: false)

      expect(payload).to include(
        'response' => 'Ada yang bisa dibantu?',
        'action' => 'reply',
        'source_type' => 'llm_rag',
        'fallback_reason' => 'no_confident_cell_match',
        'confidence' => 0.0
      )
    end
  end

  # Phase 2 — the canonical current trigger is supplied SEPARATELY (as additional_message) on
  # top of a trigger-excluded prior history, so it reaches the LLM input exactly once with no
  # duplicate current-message concatenation.
  describe 'canonical current-trigger integration (Phase 2)' do
    before do
      stub_no_translation
      allow(assistant).to receive(:config).and_return({ 'instructions' => 'You are Marine.' })
    end

    def capture_llm_messages(message: 'ok')
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      captured = { messages: nil }
      allow(llm).to receive(:chat) do |args|
        captured[:messages] = args[:messages]
        { ok: true, message: message, error: nil }
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      captured
    end

    it 'appends the separate trigger to the trigger-excluded history exactly once in the LLM input' do
      history = [
        { role: 'user', content: 'earlier customer question' },
        { role: 'assistant', content: 'earlier marine answer' }
      ]
      allow(knowledge_base).to receive(:retrieve).and_return(
        Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
      )
      captured = capture_llm_messages

      generator.generate(additional_message: 'current customer turn', message_history: history)

      contents = captured[:messages].map { |m| m[:content] || m['content'] }
      expect(contents).to eq(['earlier customer question', 'earlier marine answer', 'current customer turn'])
      expect(contents.count('current customer turn')).to eq(1)
    end
  end

  # Phase 5 — contextual wording for approved-FAQ answers ONLY. On an exact approved-FAQ
  # match the generator may replace the response BODY with validated contextual wording,
  # while every existing key/value (metadata + translation flow) stays byte-for-byte. Any
  # wording failure returns the existing translated-or-original exact fallback. Non-exact,
  # no-match/handoff, and document-backed exact results never invoke the composer.
  describe 'contextual wording for approved-FAQ answers (Phase 5)' do
    def stub_wording(candidate)
      wording = instance_double(Marine::Charge::GroundedWordingService, call: candidate)
      allow(Marine::Charge::GroundedWordingService).to receive(:new).and_return(wording)
      wording
    end

    it 'uses the accepted contextual wording while keeping all existing metadata identical' do
      stub_no_translation
      response = Marine::AssistantResponse.new(id: 9, question: 'Hi', answer: 'Hello!')
      result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 1.0)
      allow(knowledge_base).to receive(:retrieve).and_return(result)
      stub_wording('Hi there — Hello!')

      payload = generator.generate(additional_message: 'Hi')

      expect(payload['response']).to eq('Hi there — Hello!')
      expect(payload).to include(
        'action' => 'reply',
        'agent_name' => 'Marine Bot',
        'marine_cell_response_id' => 9,
        'confidence' => 1.0,
        'source_type' => 'manual',
        'response_ids' => [9],
        'document_ids' => [],
        'fallback_reason' => nil
      )
      expect(payload['citations']).to eq(result.citations)
    end

    it 'returns the exact approved answer and replies (no handoff) when the wording service declines' do
      stub_no_translation
      response = Marine::AssistantResponse.new(id: 9, question: 'Hi', answer: 'Hello!')
      result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 1.0)
      allow(knowledge_base).to receive(:retrieve).and_return(result)
      stub_wording(nil)

      payload = generator.generate(additional_message: 'Hi')

      expect(payload).to include(
        'response' => 'Hello!',
        'action' => 'reply',
        'marine_cell_response_id' => 9,
        'confidence' => 1.0,
        'source_type' => 'manual',
        'fallback_reason' => nil
      )
    end

    it 'passes the STORED approved answer (not the translated delivery fallback) to the composer and keeps translation metadata unchanged' do
      allow(Marine::Llm::TranslateQueryService).to receive(:new).and_return(
        double(call: { text: 'Where is my order', source_language: 'id', translated: true, error: nil })
      )
      allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(
        double(call: { text: 'Pesanan Anda dalam perjalanan', source_language: 'en', target_language: 'id', translated: true, error: nil })
      )
      response = Marine::AssistantResponse.new(id: 9, question: 'Where is my order', answer: 'Your order is on the way')
      result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 1.0)
      allow(knowledge_base).to receive(:retrieve).with('Where is my order', limit: 1).and_return(result)

      wording = instance_double(Marine::Charge::GroundedWordingService)
      captured = {}
      allow(wording).to receive(:call) do |args|
        captured.merge!(args)
        'Tentu! Pesanan Anda dalam perjalanan.'
      end
      allow(Marine::Charge::GroundedWordingService).to receive(:new).and_return(wording)

      history = [{ role: 'user', content: 'halo' }]
      payload = generator.generate(additional_message: 'Pesanan saya di mana', message_history: history, opening: false)

      # the composer receives the STORED approved answer as the sole authoritative factual
      # source, even though the current translation succeeded and produced a delivery fallback
      expect(captured[:approved_answer]).to eq('Your order is on the way')
      expect(captured[:customer_request]).to eq('Pesanan saya di mana')
      expect(captured[:message_history]).to eq(history)
      expect(captured[:opening]).to be(false)
      expect(payload['response']).to eq('Tentu! Pesanan Anda dalam perjalanan.')
      expect(payload).to include(
        'query_language' => 'id',
        'response_language' => 'id',
        'translated_query' => 'Where is my order',
        'translation_applied' => true,
        'response_translation_applied' => true
      )
    end

    it 'returns the exact translated delivery fallback (not the stored answer) when the composer declines' do
      allow(Marine::Llm::TranslateQueryService).to receive(:new).and_return(
        double(call: { text: 'Where is my order', source_language: 'id', translated: true, error: nil })
      )
      allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(
        double(call: { text: 'Pesanan Anda dalam perjalanan', source_language: 'en', target_language: 'id', translated: true, error: nil })
      )
      response = Marine::AssistantResponse.new(id: 9, question: 'Where is my order', answer: 'Your order is on the way')
      result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 1.0)
      allow(knowledge_base).to receive(:retrieve).with('Where is my order', limit: 1).and_return(result)

      wording = instance_double(Marine::Charge::GroundedWordingService)
      captured = {}
      allow(wording).to receive(:call) do |args|
        captured.merge!(args)
        nil
      end
      allow(Marine::Charge::GroundedWordingService).to receive(:new).and_return(wording)

      payload = generator.generate(additional_message: 'Pesanan saya di mana', opening: false)

      # composer still receives the stored answer; on decline the delivery fallback is the translation
      expect(captured[:approved_answer]).to eq('Your order is on the way')
      expect(payload['response']).to eq('Pesanan Anda dalam perjalanan')
      expect(payload).to include(
        'response_language' => 'id',
        'translation_applied' => true,
        'response_translation_applied' => true
      )
    end

    it 'does not invoke the composer on a non-exact RAG match' do
      stub_no_translation
      stub_llm_unconfigured
      allow(Marine::Charge::GroundedWordingService).to receive(:new)
      response = Marine::AssistantResponse.new(id: 7, question: 'Apa itu MOQ?', answer: 'MOQ is the minimum order quantity.')
      result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 0.5)
      allow(knowledge_base).to receive(:retrieve).and_return(result)

      payload = generator.generate(additional_message: 'Apa itu Textilindo?')

      expect(Marine::Charge::GroundedWordingService).not_to have_received(:new)
      expect(payload['response']).to eq('MOQ is the minimum order quantity.')
    end

    it 'does not invoke the composer when there is no confident match (handoff)' do
      stub_no_translation
      stub_llm_unconfigured
      allow(Marine::Charge::GroundedWordingService).to receive(:new)
      result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
      allow(knowledge_base).to receive(:retrieve).and_return(result)

      payload = generator.generate(additional_message: 'unknown')

      expect(Marine::Charge::GroundedWordingService).not_to have_received(:new)
      expect(payload).to include('action' => 'handoff')
    end

    it 'does not invoke the composer on a document-backed exact match' do
      stub_no_translation
      allow(Marine::Charge::GroundedWordingService).to receive(:new)
      response = Marine::AssistantResponse.new(id: 5, question: 'Contact', answer: 'Office: Jl. Real Address 1, Bandung.')
      result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 1.0)
      allow(result).to receive(:source_type).and_return('document')
      allow(knowledge_base).to receive(:retrieve).and_return(result)

      payload = generator.generate(additional_message: 'Contact')

      expect(Marine::Charge::GroundedWordingService).not_to have_received(:new)
      expect(payload['response']).to eq('Office: Jl. Real Address 1, Bandung.')
      expect(payload['source_type']).to eq('document')
    end
  end
end
