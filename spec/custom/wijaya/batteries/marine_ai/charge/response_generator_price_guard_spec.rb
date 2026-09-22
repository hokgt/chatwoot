# frozen_string_literal: true

require 'rails_helper'

# Numeric-price defense-in-depth for generated RAG (llm_rag) output: general RAG must never
# become a source of an invented numeric product price. A generated reply that states an explicit
# monetary amount is dropped and the caller falls CLOSED to its existing safe fallback (handoff on
# the no-match branch, the raw approved answer on the non-exact synthesis branch) — while ordinary
# non-price numbers and normal product information still flow through unchanged.
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

  def stub_rag_llm(message)
    llm = double(configured?: true)
    allow(llm).to receive(:chat).and_return({ ok: true, message: message, error: nil })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
  end

  def empty_retrieval
    Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
  end

  # A non-exact (confidence < 1.0), non-fallback retrieval whose raw approved answer is the
  # deterministic safe fallback the synthesis branch returns when the generated reply is dropped.
  def synthesis_retrieval(answer:)
    record = Marine::AssistantResponse.new(question: 'Berapa harga kainnya?', answer: answer)
    Marine::Cell::RetrievalResult.new(responses: [record], confidence: 0.6)
  end

  describe 'defense in depth — an invented numeric price is never delivered' do
    it 'drops a no-match (fallback) reply that invents a price and hands off instead of returning llm_rag' do
      allow(knowledge_base).to receive(:retrieve).and_return(empty_retrieval)
      stub_rag_llm('Harga kain Satin Velvet adalah Rp 28.500 per yard.')

      payload = generator.generate(additional_message: 'Berapa harga Satin Velvet?')

      expect(payload['action']).to eq('handoff')
      expect(payload['response']).to eq('conversation_handoff')
      expect(payload['source_type']).not_to eq('llm_rag')
      expect(payload['response']).not_to include('28.500')
    end

    it 'drops a non-exact (synthesis) reply that invents a price and returns the raw approved answer' do
      safe_answer = 'Untuk harga terbaru, saya hubungkan Anda dengan agen kami ya.'
      allow(knowledge_base).to receive(:retrieve).and_return(synthesis_retrieval(answer: safe_answer))
      stub_rag_llm('Harganya IDR 28,500 per yard.')

      payload = generator.generate(additional_message: 'Berapa harga kainnya?')

      expect(payload['action']).to eq('reply')
      expect(payload['response']).to eq(safe_answer)
      expect(payload['source_type']).not_to eq('llm_rag')
      expect(payload['response']).not_to include('28,500')
    end
  end

  describe 'normal product information still uses grounded RAG (no over-blocking)' do
    it 'returns a non-price product-information answer that contains ordinary numbers' do
      answer = 'Minimum order untuk kain ini adalah 50 yard per warna, kode variannya PL-6.'
      allow(knowledge_base).to receive(:retrieve).and_return(empty_retrieval)
      stub_rag_llm(answer)

      payload = generator.generate(additional_message: 'Berapa minimum order kain ini?')

      expect(payload['action']).to eq('reply')
      expect(payload['source_type']).to eq('llm_rag')
      expect(payload['response']).to eq(answer)
    end

    it 'returns a contact answer with a date, phone, and address (no currency-adjacent number)' do
      answer = 'Kantor kami di Jl. Sudirman No. 28. Telp +62 812 3456 7890. Buka lagi 22 September 2026.'
      allow(knowledge_base).to receive(:retrieve).and_return(empty_retrieval)
      stub_rag_llm(answer)

      payload = generator.generate(additional_message: 'Di mana alamat kantor?')

      expect(payload['action']).to eq('reply')
      expect(payload['source_type']).to eq('llm_rag')
      expect(payload['response']).to eq(answer)
    end
  end
end
