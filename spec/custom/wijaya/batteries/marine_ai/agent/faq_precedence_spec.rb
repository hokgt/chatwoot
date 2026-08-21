# frozen_string_literal: true

require 'rails_helper'

# Gate G regression — an EXACT (high-confidence) approved FAQ/KB match must take precedence over
# product orchestration, so an erroneous product classification from the untrusted LLM intent
# extractor can never preempt a curated approved answer. Genuine product requests (no exact
# approved match) still route through Product Flow, and weak / unmatched retrieval is never
# turned into a FAQ answer (fail closed).
#
# The synthetic approved FAQ mirrors the verified reproduction:
#   Q: "What is the synthetic Gate G support window?"
#   A: "The synthetic Gate G support window is 09:00–17:00 UTC on synthetic test days."
RSpec.describe 'Marine FAQ precedence over product orchestration (Gate G)', type: :model do
  let(:question) { 'What is the synthetic Gate G support window?' }
  let(:answer) { 'The synthetic Gate G support window is 09:00–17:00 UTC on synthetic test days.' }

  def approve_faq!(assistant, question_text, answer_text)
    Marine::AssistantResponse.create!(assistant: assistant, question: question_text, answer: answer_text,
                                      status: :approved, skip_embedding_enqueue: true)
  end

  # --- Deterministic routing-decision coverage at the Agent::Runner boundary -----------
  describe Marine::Agent::Runner do
    let(:account) { create(:account) }
    let(:assistant) { create(:marine_assistant, account: account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:trigger) do
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                       message_type: :incoming, content: question)
    end
    let(:runner) { described_class.new(assistant: assistant, conversation: conversation, source: trigger) }
    let(:orchestrator) { instance_double(Marine::Catalog::ProductQueryOrchestrator) }
    let(:generator) { instance_double(Marine::Charge::ResponseGenerator) }

    before do
      allow(Marine::Catalog::ProductQueryOrchestrator).to receive(:new).and_return(orchestrator)
      allow(Marine::Charge::ResponseGenerator).to receive(:new).and_return(generator)
      # An erroneous product classification: the orchestrator WOULD open a product flow.
      allow(orchestrator).to receive(:process).and_return(
        action: :clarify_variant, reply: { kind: :clarify_variant, attribute_names: [] },
        state: { operation: :start, changes: {} }
      )
      allow(generator).to receive(:generate).and_return(
        'response' => answer, 'action' => 'reply', 'agent_name' => assistant.name,
        'confidence' => 1.0, 'source_type' => 'manual'
      )
    end

    it 'vetoes product orchestration and answers via retrieval when an exact approved FAQ matches' do
      approve_faq!(assistant, question, answer)

      payload = runner.run

      expect(orchestrator).not_to have_received(:process)
      expect(payload).to include('response' => answer, 'orchestration_path' => 'retrieval', 'source_type' => 'manual')
    end

    it 'still routes to Product Flow when no approved FAQ exactly matches the turn (genuine product request)' do
      approve_faq!(assistant, 'An unrelated approved FAQ question', 'An unrelated approved answer.')

      payload = runner.run

      expect(orchestrator).to have_received(:process)
      expect(payload).to include('action' => 'product', 'orchestration_path' => 'product')
    end
  end

  # --- Full runtime path through the real ResponseBuilderJob ----------------------------
  #
  # Exercises the real chain: ResponseBuilderJob -> AssistantChatService -> Agent::Runner ->
  # (Gate G precedence) -> ResponseGenerator/product orchestration -> deterministic delivery.
  # Only true external boundaries are stubbed: the LLM provider (Marine::Llm::BaseService) and
  # the CLD3 language detector. The provider deliberately MISCLASSIFIES the FAQ question as a
  # product query, exactly as in the reproduction.
  describe 'full runtime path through ResponseBuilderJob' do
    include ActiveJob::TestHelper

    let(:conversation) { create(:conversation) }
    let(:assistant) { create(:marine_assistant, account: conversation.account) }
    let(:turn_text) { question }
    let(:trigger) { create(:message, conversation: conversation, message_type: :incoming, content: turn_text) }
    # Untrusted intent extraction MISCLASSIFIES the turn as product_related (the observed bug).
    let(:intent_json) do
      { product_related: true, intent: 'variant_info', family_mention: nil, customer_language: 'en' }.to_json
    end
    let(:base_service) { instance_double(Marine::Llm::BaseService, configured?: true) }

    def outgoing
      conversation.messages.reload.outgoing.last
    end

    def product_state
      Marine::Catalog::ProductFlowStateStore.new(conversation: conversation.reload).current
    end

    def stub_cld3(language)
      result = double('cld3_result')
      allow(result).to receive_messages(language: language, probability: 0.958, 'reliable?': true)
      identifier = instance_double(CLD3::NNetLanguageIdentifier, find_language: result)
      allow(CLD3::NNetLanguageIdentifier).to receive(:new).and_return(identifier)
    end

    before do
      allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
      allow(base_service).to receive(:complete).and_return({ ok: true, message: intent_json, error: nil })
      # Decline natural-wording generation so the exact approved answer is delivered verbatim.
      allow(base_service).to receive(:chat).and_return({ ok: false, message: nil, error: nil })
      # English turn: translation is skipped (same language) so no provider translation call runs.
      stub_cld3('en')
      clear_enqueued_jobs
      clear_performed_jobs
    end

    it 'answers from the exact approved FAQ and never opens a product flow, despite a product misclassification' do
      approve_faq!(assistant, question, answer)

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, trigger.id)

      reply = outgoing
      expect(conversation.messages.outgoing.count).to eq(1)
      expect(reply.content).to eq(answer)
      expect(reply.additional_attributes['source_type']).to eq('manual')
      expect(reply.additional_attributes['orchestration_path']).to eq('retrieval')
      expect(reply.attachments).to be_empty
      # The erroneous product classification never opened a product flow.
      expect(product_state).to be_blank
    end

    # A minimal read-only family repository over one generic synthetic row (never real product
    # data), so the genuine product turn resolves deterministically without a live catalog DB.
    class FakeFamilyRepo
      def initialize(row)
        @row = row
      end

      def resolve_exact(identifier)
        @row if identifier.to_s.strip.casecmp?(@row[:name]) || identifier.to_s.strip.casecmp?(@row[:code])
      end

      def active_candidates(query: nil, limit: 20)
        needle = query.to_s.strip.downcase
        return [@row].first(limit) if needle.empty? || @row[:name].downcase.include?(needle) || @row[:code].downcase.include?(needle)

        []
      end
    end

    context 'when the turn does not exactly match any approved FAQ (genuine product request)' do
      let(:turn_text) { 'Please send the Coastal Alpha Series catalog' }
      # A legitimate product (catalog) request the extractor classifies correctly.
      let(:intent_json) do
        { product_related: true, intent: 'catalog', family_mention: 'Coastal Alpha Series', customer_language: 'en' }.to_json
      end

      before do
        allow(Marine::Catalog::ProductFamilyRepository).to receive(:new)
          .and_return(FakeFamilyRepo.new(code: 'FAM-CAT', name: 'Coastal Alpha Series'))
      end

      it 'still routes through Product Flow rather than fabricating a FAQ answer' do
        approve_faq!(assistant, question, answer) # present, but not an exact match for this turn

        Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, trigger.id)

        reply = outgoing
        expect(reply.content).not_to eq(answer)
        expect(reply.additional_attributes['source_type']).to eq('marine_product')
        expect(reply.additional_attributes['orchestration_path']).to eq('product')
        # The product flow was engaged for the resolved family.
        expect(product_state['validated_family']).to eq('FAM-CAT')
      end
    end
  end
end
