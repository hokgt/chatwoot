# frozen_string_literal: true

require 'rails_helper'

# Regression — product-KNOWLEDGE / attribute questions must reach grounded Knowledge Base content
# instead of being deflected by the catalog layer or crowded out of the RAG grounding prompt.
#
# Two independent root-cause layers are covered, each with GENERIC synthetic product names,
# attributes, and facts (never drill/texture/Indonesian), and with two unrelated variants so the
# behavior is proven data-driven, not hardcoded:
#
#   Layer 1 (routing) — Marine::Catalog::ProductQueryOrchestrator: a non-transactional knowledge
#   intent (parent_info / variant_info) whose product family cannot be resolved carries no
#   catalog-grounded answer (the repositories hold only codes/price/stock, never textual attributes),
#   so it must DEFER to grounded KB retrieval (:not_product) rather than emit an arbitrary
#   "which product?" family clarification. Transactional intents (price/stock/catalog) still clarify
#   the family deterministically and fail closed.
#
#   Layer 2 (grounding) — Marine::Charge::ResponseGenerator: when several approved records match the
#   query, the fact the customer asked about may live in a record that is NOT the single top-ranked
#   match. The RAG grounding block must lead with the top matched records (bounded) so that fact
#   still reaches the model in full, instead of only the single best match while the fact-bearing
#   record is crowded out or truncated away.
RSpec.describe 'Marine product-knowledge grounding', type: :model do
  # --- Layer 1: catalog routing defers knowledge intents to KB -----------------------------
  describe Marine::Catalog::ProductQueryOrchestrator do
    subject(:orchestrator) do
      described_class.new(
        repositories: { family: family_repository, variant: variant_repository,
                        price: price_repository, stock: stock_repository },
        variant_resolver: variant_resolver
      )
    end

    let(:family_repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }
    let(:variant_repository) { instance_double(Marine::Catalog::VariantRepository) }
    let(:price_repository) { instance_double(Marine::Catalog::PriceRepository) }
    let(:stock_repository) { instance_double(Marine::Catalog::StockRepository) }
    let(:variant_resolver) { instance_double(Marine::Catalog::VariantResolver) }

    before do
      # The mentioned family does not resolve to any catalog family (unknown to the catalog).
      allow(family_repository).to receive(:resolve_exact).and_return(nil)
      allow(family_repository).to receive(:active_candidates).and_return([])
      allow(variant_repository).to receive(:attribute_names).and_return([])
      allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :missing)
    end

    def knowledge_intent(overrides = {})
      {
        product_related: true, intent: 'parent_info', family_mention: 'Nebula Weave',
        explicit_child_code: nil, attribute_candidates: [], requires_exact_variant: false,
        clarification_reply: nil, family_changed: false, intent_changed: false,
        multiple_numeric_candidates: false, confidence: 'high', reason: 'extracted'
      }.merge(overrides)
    end

    # Two unrelated knowledge intents, each naming an attribute the catalog cannot answer.
    [
      { intent: 'parent_info', family_mention: 'Nebula Weave' },
      { intent: 'variant_info', family_mention: 'Cobalt Mesh', requires_exact_variant: true, attribute_candidates: ['sheen'] }
    ].each do |variant|
      it "defers a #{variant[:intent]} attribute question with an unresolvable family to grounded KB (:not_product)" do
        plan = orchestrator.plan_for_intent(intent: knowledge_intent(variant), flow: nil)

        expect(plan[:action]).to eq(:not_product)
        expect(plan[:reply]).to be_nil
        expect(plan[:state]).to eq(operation: :none, changes: {})
      end
    end

    it 'still clarifies the family deterministically for a TRANSACTIONAL (price) intent (fail closed, unchanged)' do
      plan = orchestrator.plan_for_intent(intent: knowledge_intent(intent: 'price'), flow: nil)

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:reply][:kind]).to eq(:clarify_family)
    end

    # KB-availability-gated informational deferral: when the runtime reports the approved KB
    # confidently answers the turn (knowledge_available: true), an INFORMATIONAL product turn defers
    # to grounded KB retrieval (:not_product) instead of a catalog identity echo / variant
    # clarification / handoff that would HIDE the approved KB answer — even when the family resolves.
    # A transactional price/stock/catalog or exact-quantity turn is NEVER diverted. Without the signal
    # (default false) every intent keeps its unchanged deterministic catalog behavior (proven above).
    context 'when the approved KB confidently answers the turn (knowledge_available: true)' do
      before do
        # Family resolves to a concrete catalog row, so the catalog COULD deflect — the deferral must
        # still win for an informational turn because the KB actually holds the answer.
        allow(family_repository).to receive(:resolve_exact).and_return(code: 'FAM-1', name: 'Nebula Weave')
        allow(variant_repository).to receive(:attribute_names).with('FAM-1').and_return(['sheen'])
      end

      %w[parent_info variant_info unsupported unknown].each do |informational|
        it "defers an informational #{informational} turn to grounded KB (:not_product)" do
          plan = orchestrator.plan_for_intent(
            intent: knowledge_intent(intent: informational, requires_exact_variant: informational == 'variant_info'),
            flow: nil, knowledge_available: true
          )

          expect(plan[:action]).to eq(:not_product)
          expect(plan[:state]).to eq(operation: :none, changes: {})
        end
      end

      %w[price stock catalog].each do |transactional|
        it "NEVER diverts a transactional #{transactional} turn even when the KB is confident (safety)" do
          plan = orchestrator.plan_for_intent(intent: knowledge_intent(intent: transactional), flow: nil, knowledge_available: true)

          expect(plan[:action]).not_to eq(:not_product)
        end
      end

      it 'NEVER diverts an exact-quantity (quantity_inquiry) stock turn even when the KB is confident (safety)' do
        allow(family_repository).to receive(:resolve_exact).and_return(code: 'FAM-1', name: 'Nebula Weave')
        plan = orchestrator.plan_for_intent(
          intent: knowledge_intent(intent: 'stock', quantity_inquiry: true), flow: nil, knowledge_available: true
        )

        expect(plan[:action]).not_to eq(:not_product)
      end
    end
  end

  # --- Layer 2: RAG grounding leads with the top matched records ---------------------------
  describe Marine::Charge::ResponseGenerator do
    let(:account) { create(:account) }
    let(:assistant) { create(:marine_assistant, account: account) }
    let(:base_service) { instance_double(Marine::Llm::BaseService, configured?: true) }

    # >500 chars of query-token-free filler so the appended fact sentence sits PAST the per-entry
    # truncation cutoff — it only survives when its record is grounded in FULL (a top matched
    # record), never as a truncated breadth entry.
    def padded(fact_sentence)
      filler = 'Please consult additional catalog notes regarding related items and general guidance. ' * 7
      "#{filler}#{fact_sentence}"
    end

    def approve!(question, answer)
      Marine::AssistantResponse.create!(assistant: assistant, question: question, answer: answer,
                                        status: :approved, skip_embedding_enqueue: true)
    end

    before do
      allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
      # No translation provider calls: the query and answer stay in the knowledge language.
      allow(Marine::Llm::TranslateQueryService).to receive(:new)
        .and_return(instance_double(Marine::Llm::TranslateQueryService,
                                    call: { ok: true, text: nil, source_language: 'en', translated: false, error: nil }))
      allow(Marine::Llm::TranslateResponseService).to receive(:new)
        .and_return(instance_double(Marine::Llm::TranslateResponseService,
                                    call: { ok: true, text: nil, target_language: 'en', translated: false, error: nil }))
    end

    # query, decoy question/answer (ranks #1, no fact), fact question (ranks lower), fact needle.
    [
      { query: 'zeta surface texture question',
        decoy_q: 'zeta surface texture info', decoy_a: 'zeta surface texture zeta surface texture',
        fact_q: 'zeta surface composition',
        fact_a: 'The material shows a diagonal woven grain and is highly durable.',
        needle: 'diagonal woven grain' },
      { query: 'quorix coating durability query',
        decoy_q: 'quorix coating durability data', decoy_a: 'quorix coating durability quorix coating durability',
        fact_q: 'quorix coating spec',
        fact_a: 'Recommended care is a gentle cold hand-wash only.',
        needle: 'gentle cold hand-wash' }
    ].each do |v|
      it "grounds the LLM on a lower-ranked matched record holding the fact (#{v[:needle]})" do
        approve!(v[:decoy_q], v[:decoy_a])
        approve!(v[:fact_q], padded(v[:fact_a]))

        captured_system = nil
        allow(base_service).to receive(:chat) do |args|
          captured_system = args[:system]
          { ok: false, message: nil, error: nil }
        end

        described_class.new(assistant: assistant).generate(additional_message: v[:query])

        expect(base_service).to have_received(:chat)
        expect(captured_system).to include(v[:needle])
      end
    end
  end
end
