# frozen_string_literal: true

require 'rails_helper'

# Numeric-price defense-in-depth for generated RAG (llm_rag) output: general RAG must never become a
# source of an invented numeric product price, and — more broadly — must never state a MATERIAL
# number that is not grounded in the approved Knowledge Base context it was given.
#
#   * A generated reply that states a monetary/unit-rate price by SHAPE (currency-tagged OR a bare
#     "<amount> per <unit>" / "<amount>/<unit>") is dropped.
#   * A generated reply that states any material number ABSENT from the approved grounding (an
#     invented amount/MOQ/date/contact — including a bare price with no currency token or rate unit)
#     is dropped.
#   * The caller then falls CLOSED to its existing safe fallback (handoff on the no-match branch; the
#     raw approved answer on the non-exact synthesis branch — and even that raw answer fails closed to
#     a handoff when it ITSELF carries a monetary/unit-rate price, so a non-deterministic price can
#     never bypass the deterministic catalog pricing path).
#   * Normal product information whose numbers ARE grounded still flows through unchanged.
RSpec.describe Marine::Charge::ResponseGenerator do
  let(:assistant) { double('assistant', name: 'Marine Bot') }
  let(:knowledge_base) { instance_double(Marine::Cell::KnowledgeBaseService) }
  let(:generator) { described_class.new(assistant: assistant) }

  before do
    allow(assistant).to receive(:config).and_return({ 'instructions' => 'You are Marine.' })
    allow(Marine::Cell::KnowledgeBaseService).to receive(:new).with(assistant: assistant).and_return(knowledge_base)
    allow(Marine::Llm::TranslateQueryService).to receive(:new).and_return(
      double(call: { text: nil, source_language: 'id', translated: false, error: nil })
    )
    allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(
      double(call: { text: nil, source_language: 'id', target_language: 'id', translated: false, error: nil })
    )
  end

  # The FIRST retrieve (limit: 1) selects the branch; the grounding retrieve (limit: RAG_GROUNDING_MATCHES)
  # seeds the approved context the numeric-grounding guard checks against. The assistant double owns no
  # #responses, so default_knowledge_base_entries is empty and grounding == the stubbed grounding records.
  def stub_retrieve(first:, grounding: [])
    allow(knowledge_base).to receive(:retrieve) do |_query, limit:|
      limit == 1 ? first : Marine::Cell::RetrievalResult.new(responses: grounding, confidence: 0.0)
    end
  end

  def stub_rag_llm(message)
    llm = double(configured?: true)
    allow(llm).to receive(:chat).and_return({ ok: true, message: message, error: nil })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
  end

  def stub_rag_llm_unconfigured
    allow(Marine::Llm::BaseService).to receive(:new).and_return(double(configured?: false))
  end

  def empty_retrieval
    Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
  end

  # A non-exact (confidence < 1.0), non-fallback retrieval whose raw approved answer is the
  # deterministic safe fallback the synthesis branch returns when the generated reply is dropped.
  def synthesis_retrieval(answer:)
    record = Marine::AssistantResponse.new(id: 1, question: 'Berapa harga kainnya?', answer: answer)
    Marine::Cell::RetrievalResult.new(responses: [record], confidence: 0.6)
  end

  def kb_record(answer)
    Marine::AssistantResponse.new(id: 42, question: 'Info', answer: answer)
  end

  describe 'defense in depth — an invented numeric price is never delivered (no-match branch)' do
    it 'drops a currency-tagged invented price and hands off' do
      stub_retrieve(first: empty_retrieval)
      stub_rag_llm('Harga kain Satin Velvet adalah Rp 28.500 per yard.')

      payload = generator.generate(additional_message: 'Berapa harga Satin Velvet?')

      expect(payload['action']).to eq('handoff')
      expect(payload['response']).to eq('conversation_handoff')
      expect(payload['source_type']).not_to eq('llm_rag')
      expect(payload.to_s).not_to include('28.500')
    end

    it 'drops a BARE unit-rate invented price with no currency token and hands off' do
      stub_retrieve(first: empty_retrieval)
      stub_rag_llm('Kira-kira 28.500 per yard ya.')

      payload = generator.generate(additional_message: 'Berapa harganya?')

      expect(payload['action']).to eq('handoff')
      expect(payload.to_s).not_to include('28.500')
    end

    it 'drops a "<amount>/<unit>" invented price with no currency token and hands off' do
      stub_retrieve(first: empty_retrieval)
      stub_rag_llm('Sekitar 28500/yard.')

      payload = generator.generate(additional_message: 'Berapa harganya?')

      expect(payload['action']).to eq('handoff')
      expect(payload.to_s).not_to include('28500')
    end

    it 'drops a BARE invented amount (no currency token, no rate unit) that is ungrounded and hands off' do
      stub_retrieve(first: empty_retrieval, grounding: [])
      stub_rag_llm('Harganya 28500 saja.')

      payload = generator.generate(additional_message: 'Berapa harganya?')

      expect(payload['action']).to eq('handoff')
      expect(payload.to_s).not_to include('28500')
    end
  end

  describe 'non-exact synthesis branch — a rejected generated price cannot fall through to a raw price' do
    it 'drops a non-exact synthesis reply that invents a price and returns the SAFE raw approved answer' do
      safe_answer = 'Untuk harga terbaru, saya hubungkan Anda dengan agen kami ya.'
      stub_retrieve(first: synthesis_retrieval(answer: safe_answer))
      stub_rag_llm('Harganya IDR 28,500 per yard.')

      payload = generator.generate(additional_message: 'Berapa harga kainnya?')

      expect(payload['action']).to eq('reply')
      expect(payload['response']).to eq(safe_answer)
      expect(payload['source_type']).not_to eq('llm_rag')
      expect(payload['response']).not_to include('28,500')
    end

    it 'fails CLOSED to a handoff when the RAW non-exact answer itself carries a monetary price (defect 3)' do
      priced_answer = 'Harga kain ini Rp 12.500 per yard.'
      stub_retrieve(first: synthesis_retrieval(answer: priced_answer))
      stub_rag_llm_unconfigured # synthesis declines for a NON-price reason; the raw price must still fail closed

      payload = generator.generate(additional_message: 'Berapa harga kainnya?')

      expect(payload['action']).to eq('handoff')
      expect(payload['response']).to eq('conversation_handoff')
      expect(payload.to_s).not_to include('12.500')
    end
  end

  describe 'normal product information still uses grounded RAG (no over-blocking)' do
    it 'returns a contact answer whose date, phone, and address numbers ARE grounded in the KB context' do
      answer = 'Kantor kami di Jl. Sudirman No. 28. Telp +62 812 3456 7890. Buka lagi 22 September 2026.'
      grounding = 'Alamat: Jl. Sudirman No. 28. Telepon: +62 812 3456 7890. Kami buka kembali 22 September 2026.'
      stub_retrieve(first: empty_retrieval, grounding: [kb_record(grounding)])
      stub_rag_llm(answer)

      payload = generator.generate(additional_message: 'Di mana alamat kantor?')

      expect(payload['action']).to eq('reply')
      expect(payload['source_type']).to eq('llm_rag')
      expect(payload['response']).to eq(answer)
    end

    it 'returns a grounded MOQ answer (material quantity present in the KB context)' do
      answer = 'Minimum order untuk kain ini adalah 500 yard, kode variannya PL-6.'
      grounding = 'MOQ kain ini 500 yard per warna. Kode varian PL-6.'
      stub_retrieve(first: empty_retrieval, grounding: [kb_record(grounding)])
      stub_rag_llm(answer)

      payload = generator.generate(additional_message: 'Berapa minimum order kain ini?')

      expect(payload['action']).to eq('reply')
      expect(payload['source_type']).to eq('llm_rag')
      expect(payload['response']).to eq(answer)
    end
  end

  describe 'invented ungrounded numeric facts fail closed (grounding guard)' do
    it 'drops an answer whose MOQ is invented (absent from the KB context) and hands off' do
      grounding = 'MOQ kain ini 500 yard per warna.'
      stub_retrieve(first: empty_retrieval, grounding: [kb_record(grounding)])
      stub_rag_llm('Minimum order kain ini adalah 5000 yard.')

      payload = generator.generate(additional_message: 'Berapa minimum order?')

      expect(payload['action']).to eq('handoff')
      expect(payload.to_s).not_to include('5000')
    end
  end
end
