# frozen_string_literal: true

require 'rails_helper'

# Routing-level acceptance for the numeric-price boundary:
#   * a deterministic product price (or a deterministic unavailable/handoff plan) is served by the
#     product orchestration path and never reaches general RAG (A / B);
#   * a source-less Playground price follow-up that falls through to general RAG can never emit an
#     invented numeric amount — the RAG guard fails it closed to the canonical handoff (C).
RSpec.describe Marine::Agent::Runner, type: :model do
  describe 'deterministic product pricing preempts general RAG (A / B)' do
    let(:account) { create(:account) }
    let(:assistant) { create(:marine_assistant, account: account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:trigger) { create(:message, conversation: conversation, message_type: :incoming, content: 'Berapa harga Satin Velvet?') }
    let(:runner) { described_class.new(assistant: assistant, conversation: conversation, source: trigger) }
    let(:orchestrator) { instance_double(Marine::Catalog::ProductQueryOrchestrator) }
    let(:knowledge_base) { instance_double(Marine::Cell::KnowledgeBaseService) }

    before do
      allow(Marine::Catalog::IntentExtractor).to receive(:new).and_return(double('intent_extractor'))
      allow(Marine::Catalog::ProductQueryOrchestrator).to receive(:new).and_return(orchestrator)
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(knowledge_base)
      # Non-exact retrieval: Gate G FAQ precedence never fires, so the product path owns the turn.
      allow(knowledge_base).to receive(:retrieve).and_return(
        Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
      )
      allow(Marine::Catalog::ProductFlowStateStore).to receive(:new).and_return(
        double('flow_store', current_for_planning: nil)
      )
    end

    it 'returns the deterministic product plan for a valid price and never invokes RAG (A)' do
      allow(orchestrator).to receive(:process).and_return({ action: :price, variant_code: 'SV-1' })
      expect(Marine::Charge::ResponseGenerator).not_to receive(:new)

      payload = runner.run

      expect(payload['action']).to eq('product')
      expect(payload['orchestration_path']).to eq('product')
      expect(payload['product_plan']).to eq({ action: :price, variant_code: 'SV-1' })
    end

    it 'returns the deterministic unavailable/handoff plan and never invokes RAG (B)' do
      allow(orchestrator).to receive(:process).and_return({ action: :handoff, reason: :price_unavailable })
      expect(Marine::Charge::ResponseGenerator).not_to receive(:new)

      payload = runner.run

      expect(payload['action']).to eq('product')
      expect(payload['product_plan']).to eq({ action: :handoff, reason: :price_unavailable })
    end
  end

  describe 'source-less Playground price follow-up cannot emit an invented price (C)' do
    let(:account) { create(:account) }
    let(:assistant) { create(:marine_assistant, account: account) }
    let(:runner) { described_class.new(assistant: assistant, source: 'playground') }
    let(:knowledge_base) { instance_double(Marine::Cell::KnowledgeBaseService) }

    before do
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(knowledge_base)
      allow(knowledge_base).to receive(:retrieve).and_return(
        Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
      )
      # The catalog preview declines this turn (non-product / no deterministic price), and the domain
      # boundary allows it, so it falls through to general RAG exactly as the incident did.
      allow(Marine::Catalog::PlaygroundPreview).to receive(:new).and_return(double('preview', call: nil))
      allow(Marine::Circuit::DomainBoundaryGuard).to receive(:new).and_return(
        instance_double(Marine::Circuit::DomainBoundaryGuard, call: nil)
      )
      allow(Marine::Llm::TranslateQueryService).to receive(:new).and_return(
        double(call: { text: nil, source_language: 'id', translated: false, error: nil })
      )
      allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(
        double(call: { text: nil, source_language: 'id', target_language: 'id', translated: false, error: nil })
      )
      llm = double(configured?: true)
      allow(llm).to receive(:chat).and_return({ ok: true, message: 'Harga kain Satin Velvet adalah Rp 28.500 per yard.', error: nil })
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    end

    it 'fails the invented RAG price closed to a handoff' do
      payload = runner.run(additional_message: 'Berapa harganya?')

      expect(payload['action']).to eq('handoff')
      expect(payload['response']).to eq('conversation_handoff')
      expect(payload.to_s).not_to include('28.500')
    end
  end
end
