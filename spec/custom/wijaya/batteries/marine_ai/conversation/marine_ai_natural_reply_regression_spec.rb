# frozen_string_literal: true

require 'rails_helper'

# Phase 7 — REGRESSION coverage for the customer-facing reply quality fixes:
#   * an exact-quantity ("how many") question hands off safely instead of answering with a
#     misleading boolean stock sentence, while PRESERVING the validated family context;
#   * a plain availability question still answers boolean stock (the fix is surgical);
#   * an ambiguous family still fails closed to clarify_family even for a quantity question;
#   * a price reply carries grounded product context (the validated variant it prices);
#   * a catalog follow-up reuses the validated family in focus instead of re-clarifying;
#   * a product handoff posts a context-aware, unbranded acknowledgement (natural when available,
#     deterministic on model failure) — never the generic branded default; and
#   * the post-handoff suppression safeguard and per-message idempotency remain intact.
RSpec.describe 'Marine natural reply regression' do
  describe 'orchestrator decisions' do
    subject(:orchestrator) do
      Marine::Catalog::ProductQueryOrchestrator.new(
        repositories: { family: family_repository, variant: variant_repository, price: price_repository, stock: stock_repository },
        variant_resolver: variant_resolver
      )
    end

    let(:family_repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }
    let(:variant_repository) { instance_double(Marine::Catalog::VariantRepository) }
    let(:price_repository) { instance_double(Marine::Catalog::PriceRepository) }
    let(:stock_repository) { instance_double(Marine::Catalog::StockRepository) }
    let(:variant_resolver) { instance_double(Marine::Catalog::VariantResolver) }
    let(:available_price) { { status: :available, price_list_rate: '125.50', currency: 'USD', uom: 'Nos' } }

    before do
      allow(family_repository).to receive(:resolve_exact).and_return(code: 'FAM-1', name: 'Impeller')
      allow(family_repository).to receive(:active_candidates).and_return([])
      allow(variant_repository).to receive(:attribute_names).and_return(%w[Size])
      allow(variant_repository).to receive(:resolve_child).and_return(nil)
      allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1')
      allow(price_repository).to receive(:price_for).and_return(status: :unavailable)
      allow(stock_repository).to receive(:status_for).and_return(:available)
    end

    def intent(overrides = {})
      {
        product_related: true, intent: 'stock', family_mention: 'Impeller', explicit_child_code: 'CHILD-1',
        attribute_candidates: [], requires_exact_variant: false, clarification_reply: nil,
        family_changed: false, intent_changed: false, multiple_numeric_candidates: false,
        quantity_inquiry: false, confidence: 'high', reason: 'extracted'
      }.merge(overrides)
    end

    it 'hands off a quantity question safely, never reading stock, and preserves the family' do
      plan = orchestrator.plan_for_intent(intent: intent(quantity_inquiry: true), flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply]).to eq(kind: :unsupported)
      expect(plan[:state][:changes]).to include('validated_family' => 'FAM-1')
      expect(stock_repository).not_to have_received(:status_for)
    end

    it 'still answers a plain availability question with a boolean stock reply (surgical)' do
      allow(stock_repository).to receive(:status_for).with('CHILD-1').and_return(:available)

      plan = orchestrator.plan_for_intent(intent: intent(quantity_inquiry: false), flow: nil)

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply]).to eq(kind: :stock_available, variant_code: 'CHILD-1')
    end

    it 'still fails closed to clarify_family for a quantity question on an ambiguous family' do
      allow(family_repository).to receive(:resolve_exact).and_return(nil)
      allow(family_repository).to receive(:active_candidates)
        .and_return([{ code: 'FAM-1', name: 'A' }, { code: 'FAM-2', name: 'B' }])

      plan = orchestrator.plan_for_intent(intent: intent(quantity_inquiry: true, explicit_child_code: nil, family_mention: 'pump'), flow: nil)

      expect(plan[:action]).to eq(:clarify_family)
    end

    it 'grounds a price reply with the validated variant it prices' do
      allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1')
      allow(price_repository).to receive(:price_for).with('CHILD-1').and_return(available_price)

      plan = orchestrator.plan_for_intent(intent: intent(intent: 'price', requires_exact_variant: true), flow: nil)

      expect(plan[:reply]).to eq(kind: :price_available, variant_code: 'CHILD-1', price_list_rate: '125.50', currency: 'USD', uom: 'Nos')
    end

    it 'reuses the validated family in focus for a catalog follow-up instead of re-clarifying' do
      flow = {
        'version' => 2, 'flow_id' => 'flow-1', 'status' => 'active',
        'expires_at' => '2999-01-01T00:00:00Z', 'validated_family' => 'FAM-1', 'current_intent' => 'catalog'
      }

      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'catalog', family_mention: nil, explicit_child_code: nil), flow: flow
      )

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-1', family_name: 'Impeller')
    end

    it 'tags a quantity handoff with the exact_quantity request category (never a fabricated value)' do
      plan = orchestrator.plan_for_intent(intent: intent(quantity_inquiry: true), flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:handoff_category]).to eq('exact_quantity')
    end

    it 'threads a bounded allowlisted unsupported-request category onto an unsupported-intent handoff' do
      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'unsupported', unsupported_request: 'shipping_cost', explicit_child_code: nil), flow: nil
      )

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply]).to eq(kind: :unsupported)
      expect(plan[:handoff_category]).to eq('shipping_cost')
    end

    it 'drops a malformed unsupported-request category so the handoff stays generic (fail closed)' do
      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'unsupported', unsupported_request: 'wire_me_money', explicit_child_code: nil), flow: nil
      )

      expect(plan[:action]).to eq(:handoff)
      expect(plan).not_to have_key(:handoff_category)
    end
  end

  describe 'product handoff acknowledgement delivery (job)' do
    let(:conversation) { create(:conversation) }
    let(:assistant) { create(:marine_assistant, account: conversation.account) }
    let(:incoming) { create(:message, conversation: conversation, message_type: :incoming, content: 'can you deliver to my city and how much?') }

    def stub_reasoning(payload)
      chat = instance_double(Marine::Llm::AssistantChatService, generate_response: payload)
      allow(Marine::Llm::AssistantChatService).to receive(:new).and_return(chat)
    end

    def handoff_payload(category: nil)
      plan = { action: :handoff, reply: { kind: :unsupported }, state: { operation: :none, changes: {} } }
      plan[:handoff_category] = category if category
      { 'action' => 'product', 'orchestration_path' => 'product', 'product_plan' => plan }
    end

    def stub_handoff_wording(result)
      allow(Marine::Catalog::GroundedHandoffWordingService).to receive(:new)
        .and_return(instance_double(Marine::Catalog::GroundedHandoffWordingService, call: result))
    end

    def public_reply
      conversation.messages.outgoing.where(private: false).last
    end

    # Category -> its deterministic English acknowledgement (the exact production constant), so the
    # test asserts against real production copy rather than re-hardcoding wording here.
    ack_for = Marine::Catalog::ReplyPresenter::HANDOFF_ACK_BY_CATEGORY

    ack_for.each do |category, english_ack|
      it "acknowledges the #{category} request with its category-specific unbranded line on model failure (EN)" do
        stub_reasoning(handoff_payload(category: category))
        stub_handoff_wording(nil) # natural wording unavailable -> deterministic category acknowledgement

        Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)

        expect(public_reply.content).to eq(english_ack)
        expect(public_reply.content).not_to eq(Marine::Catalog::ReplyPresenter::HANDOFF_ACK_TEXT)
        expect(public_reply.content).not_to eq(Marine::Circuit::HandoffService::DEFAULT_MESSAGE)
      end
    end

    it 'delivers a natural request-aware acknowledgement (e.g. Indonesian) verbatim when the wording service returns one' do
      stub_reasoning(handoff_payload(category: 'delivery_feasibility'))
      stub_handoff_wording('Baik, saya minta rekan kami menindaklanjuti soal pengiriman ke lokasi Anda.')

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)

      expect(public_reply.content).to eq('Baik, saya minta rekan kami menindaklanjuti soal pengiriman ke lokasi Anda.')
    end

    it 'falls back to the fully generic factless line for an unknown/other/missing category (fail closed)' do
      stub_reasoning(handoff_payload(category: 'other'))
      stub_handoff_wording(nil)

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)

      expect(public_reply.content).to eq(Marine::Catalog::ReplyPresenter::HANDOFF_ACK_TEXT)
    end

    it 'hardcodes no brand/customer/product/destination/price value in any deterministic acknowledgement' do
      lines = ack_for.values + [Marine::Catalog::ReplyPresenter::HANDOFF_ACK_TEXT]
      lines.each do |line|
        expect(line).not_to match(/\d/)                 # no quantity/price/coverage figure
        expect(line).not_to match(/\p{Sc}/)             # no currency symbol
        expect(line).not_to match(/\b[A-Z]{2,}\b/)      # no bare uppercase code
        # the delivery line may say "the location you mentioned" generically but names no destination
        expect(line.downcase).not_to include('surabaya')
        expect(line.downcase).not_to include('jakarta')
      end
    end

    it 'delivers a natural, context-aware acknowledgement when the wording service returns one' do
      stub_reasoning(handoff_payload)
      stub_handoff_wording('I understand you want delivery to your city — a colleague will follow up on that for you.')

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)

      expect(public_reply.content).to eq('I understand you want delivery to your city — a colleague will follow up on that for you.')
      expect(public_reply.content).not_to eq(Marine::Circuit::HandoffService::DEFAULT_MESSAGE)
    end

    it 'falls back to the deterministic unbranded acknowledgement on model failure (never the generic default)' do
      stub_reasoning(handoff_payload)
      stub_handoff_wording(nil)

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)

      expect(public_reply.content).to eq(Marine::Catalog::ReplyPresenter::HANDOFF_ACK_TEXT)
      expect(public_reply.content).not_to eq(Marine::Circuit::HandoffService::DEFAULT_MESSAGE)
    end

    it 'suppresses every Marine reply after the handoff is active (safeguard intact)' do
      stub_reasoning(handoff_payload)
      stub_handoff_wording(nil)
      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)
      after_handoff = conversation.messages.outgoing.count

      later = create(:message, conversation: conversation, message_type: :incoming, content: 'are you there?')
      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, later.id)

      expect(conversation.messages.outgoing.count).to eq(after_handoff)
    end

    it 'is idempotent — a duplicate delivery of the same trigger posts one public handoff line' do
      stub_reasoning(handoff_payload)
      stub_handoff_wording(nil)

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)
      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)

      expect(conversation.messages.outgoing.where(private: false).count).to eq(1)
    end
  end

  # Finding #1 — a DIRECT catalog caption is eligible for the fact-protected natural-wording path
  # and precomputed lock-free; finalize delivers the precomputed text and NEVER localizes under the
  # row lock; a race that changes the outcome after precompute fails safely to deterministic
  # English with no under-lock network call.
  describe 'direct catalog caption naturalization (job)' do
    let(:conversation) { create(:conversation) }
    let(:assistant) { create(:marine_assistant, account: conversation.account) }
    let(:incoming) { create(:message, conversation: conversation, message_type: :incoming, content: 'please send me the impeller catalog') }

    def stub_reasoning(payload)
      allow(Marine::Llm::AssistantChatService).to receive(:new)
        .and_return(instance_double(Marine::Llm::AssistantChatService, generate_response: payload))
    end

    def direct_catalog_payload
      { 'action' => 'product', 'orchestration_path' => 'product',
        'product_plan' => { action: :send_catalog, reply: { kind: :catalog, family_code: 'IMP', family_name: 'Impeller' },
                            state: { operation: :start, changes: { 'validated_family' => 'IMP', 'current_intent' => 'catalog' } } } }
    end

    def usable_catalog
      create(:marine_document, :product_catalog, assistant: assistant, product_family_code: 'IMP', status: :available)
    end

    def last_reply
      conversation.messages.outgoing.where(private: false).last
    end

    # The finalize row lock. The lock-free precompute runs BEFORE this lock and may legitimately
    # localize/naturalize the predicted caption (CLD3 can even misclassify an English caption and
    # reach the translator); the contract is only that NO translation, natural wording, or semantic
    # validation runs WHILE the Conversation row lock is held. Returns a mutable holder whose
    # [:held] flag is true for exactly the duration of the finalize lock.
    def observing_finalize_lock
      lock = { held: false }
      allow(conversation).to receive(:with_lock).and_wrap_original do |method, *args, &block|
        lock[:held] = true
        method.call(*args, &block)
      ensure
        lock[:held] = false
      end
      lock
    end

    # Deterministically rejects construction of a translation/natural-wording/semantic-validator
    # service while the finalize lock is held, so an under-lock network call is caught instead of
    # slipping through a global zero-call assertion. Before the lock it returns the supplied
    # lock-free `stub`.
    def reject_under_lock(klass, lock, stub:)
      allow(klass).to receive(:new).and_wrap_original do |_method, *_args, **_kwargs|
        raise "#{klass} constructed under the finalize row lock" if lock[:held]

        stub
      end
    end

    it 'delivers a natural, grounded caption for a direct catalog request with the attachment intact' do
      document = usable_catalog
      stub_reasoning(direct_catalog_payload)
      captured = {}
      service = instance_double(Marine::Catalog::GroundedProductWordingService)
      allow(service).to receive(:call) do |args|
        captured.merge!(args)
        'Of course — here is the Impeller catalog you asked for.'
      end
      allow(Marine::Catalog::GroundedProductWordingService).to receive(:new).and_return(service)

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)

      expect(last_reply.content).to eq('Of course — here is the Impeller catalog you asked for.')
      expect(last_reply.attachments.count).to eq(1)
      expect(last_reply.attachments.first.file.blob.id).to eq(document.source_file.blob.id)
      # Grounded on the :catalog descriptor + the EXACT deterministic caption fallback (fact-protected).
      expect(captured[:action]).to eq(:send_catalog)
      expect(captured[:descriptor]).to include(kind: :catalog, family_name: 'Impeller')
      expect(captured[:fallback]).to eq('Here is the product catalog for Impeller.')
    end

    it 'does not localize under the finalize lock — the caption is prepared exactly once lock-free' do
      usable_catalog
      stub_reasoning(direct_catalog_payload)
      # Wording declines (unavailable) so the deterministic localized caption is delivered verbatim.
      allow(Marine::Catalog::GroundedProductWordingService).to receive(:new)
        .and_return(instance_double(Marine::Catalog::GroundedProductWordingService, call: nil))
      localizer_calls = 0
      allow(Marine::Catalog::ReplyLocalizer).to receive(:new).and_wrap_original do |method, **kwargs|
        localizer_calls += 1
        method.call(**kwargs)
      end

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)

      expect(last_reply.content).to eq('Here is the product catalog for Impeller.')
      expect(localizer_calls).to eq(1) # only the lock-free precompute; finalize did not re-localize
    end

    it 'fails safely to the deterministic English fallback with no under-lock network when the outcome changes after precompute (race)' do
      document = usable_catalog
      stub_reasoning(direct_catalog_payload)
      # Race: the catalog exists at lock-free precompute but is gone when finalize re-selects under
      # the row lock, so the outcome+document signature no longer matches.
      selector = instance_double(Marine::Documents::ProductCatalogSelector)
      results = [document, nil]
      allow(selector).to receive(:call) { results.shift }
      allow(Marine::Documents::ProductCatalogSelector).to receive(:new).and_return(selector)
      # The lock-free precompute may localize/naturalize the predicted caption exactly once BEFORE the
      # lock — that is allowed. What must NEVER happen is a translation, natural-wording, or semantic-
      # validator call WHILE the finalize row lock is held: the under-lock mismatch path delivers
      # deterministic English with no network. Observe the lock and reject any such under-lock call.
      lock = observing_finalize_lock
      reject_under_lock(Marine::Llm::TranslateResponseService, lock,
                        stub: instance_double(Marine::Llm::TranslateResponseService, call: { ok: false, text: nil, translated: false }))
      reject_under_lock(Marine::Catalog::GroundedProductWordingService, lock,
                        stub: instance_double(Marine::Catalog::GroundedProductWordingService, call: 'Of course — here is the Impeller catalog.'))
      reject_under_lock(Marine::Charge::FactPreservationValidator, lock,
                        stub: instance_double(Marine::Charge::FactPreservationValidator, valid?: true))

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)

      expect(last_reply.content).to eq("I'm sorry, I don't have a catalog available for Impeller right now.")
      expect(last_reply.attachments).to be_empty
    end
  end
end
