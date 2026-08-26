# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Conversation::ResponseBuilderJob do
  describe '#create_marine_reply' do
    let(:assistant) { double('assistant') }
    let(:messages) { double('messages') }
    let(:conversation) { double('conversation', account_id: 11, inbox_id: 22, messages: messages) }
    let(:job) { described_class.new }

    it 'persists confidence and citation metadata alongside legacy attributes' do
      job.instance_variable_set(:@conversation, conversation)
      job.instance_variable_set(:@assistant, assistant)
      job.instance_variable_set(:@response, {
                                  'response' => 'Hello!',
                                  'agent_name' => 'Marine Bot',
                                  'marine_cell_response_id' => 9,
                                  'confidence' => 0.9,
                                  'citations' => [{ response_id: 9, question: 'Hi', source_type: 'manual' }],
                                  'source_type' => 'manual',
                                  'response_ids' => [9],
                                  'document_ids' => [],
                                  'fallback_reason' => nil
                                })

      expect(messages).to receive(:create!).with(
        hash_including(
          additional_attributes: {
            agent_name: 'Marine Bot',
            marine_cell_response_id: 9,
            confidence: 0.9,
            citations: [{ response_id: 9, question: 'Hi', source_type: 'manual' }],
            source_type: 'manual',
            response_ids: [9],
            document_ids: []
          }
        )
      )

      job.send(:create_marine_reply)
    end
  end

  describe '#perform (trigger-bound Phase 5)' do
    let(:conversation) { create(:conversation) }
    let(:assistant) { create(:marine_assistant, account: conversation.account) }
    let(:incoming) { create(:message, conversation: conversation, message_type: :incoming, content: 'price for impeller 3 inch') }

    def stub_reasoning(payload)
      chat = instance_double(Marine::Llm::AssistantChatService, generate_response: payload)
      allow(Marine::Llm::AssistantChatService).to receive(:new).and_return(chat)
    end

    def product_payload(action:, reply: nil, operation: :none, changes: {})
      {
        'action' => 'product', 'orchestration_path' => 'product',
        'product_plan' => { action: action, reply: reply, state: { operation: operation, changes: changes } }
      }
    end

    def claim_status
      incoming.reload.additional_attributes.dig('wijaya_marine_ai', 'processing_claim_v1', 'status')
    end

    def usage_count
      conversation.account.reload.custom_attributes['marine_responses_usage'].to_i
    end

    def product_state
      Marine::Catalog::ProductFlowStateStore.new(conversation: conversation.reload).current
    end

    it 'creates a deterministic product text reply, applies flow state, and completes the claim' do
      stub_reasoning(product_payload(
                       action: :reply,
                       reply: { kind: :price_available, currency: 'IDR', price_list_rate: '150000', uom: 'pcs' },
                       operation: :update,
                       changes: { 'validated_family' => 'IMP', 'validated_variant' => 'IMP-3', 'current_intent' => 'price' }
                     ))

      described_class.perform_now(conversation, assistant, incoming.id)

      conversation.messages.reload
      reply = conversation.messages.outgoing.last
      expect(reply.content).to eq('The price is IDR 150000 per pcs.')
      expect(reply.additional_attributes['source_type']).to eq('marine_product')
      expect(reply.attachments).to be_empty
      expect(product_state['validated_variant']).to eq('IMP-3')
      expect(usage_count).to eq(1)
      expect(claim_status).to eq('completed')
    end

    it 'produces no second output and no double usage on a duplicate delivery of the same incoming message' do
      stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available }))

      described_class.perform_now(conversation, assistant, incoming.id)
      described_class.perform_now(conversation, assistant, incoming.id)

      expect(conversation.messages.outgoing.count).to eq(1)
      expect(usage_count).to eq(1)
    end

    it 'stops without output when a newer relevant incoming message exists (stale job)' do
      trigger = incoming # force the trigger message to exist BEFORE the newer one
      create(:message, conversation: conversation, message_type: :incoming, content: 'actually, a different question')
      baseline = conversation.messages.outgoing.count
      stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available }))

      described_class.perform_now(conversation, assistant, trigger.id)

      expect(conversation.messages.outgoing.count).to eq(baseline)
      expect(claim_status).to eq('completed')
    end

    it 'creates no Marine output when a human takes over DURING reasoning/finalization' do
      chat = instance_double(Marine::Llm::AssistantChatService)
      allow(Marine::Llm::AssistantChatService).to receive(:new).and_return(chat)
      allow(chat).to receive(:generate_response) do
        # takeover appears only after pre-reasoning eligibility passed
        create(:message, conversation: conversation, message_type: :outgoing, sender: create(:user, account: conversation.account))
        product_payload(action: :reply, reply: { kind: :stock_available })
      end

      described_class.perform_now(conversation, assistant, incoming.id)

      expect(conversation.messages.outgoing.where.not(sender_type: 'User').count).to eq(0)
      expect(claim_status).to eq('completed')
    end

    it 'stops without output when a human agent has taken over before reasoning' do
      create(:message, conversation: conversation, message_type: :outgoing, sender: create(:user, account: conversation.account))
      stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available }))

      described_class.perform_now(conversation, assistant, incoming.id)

      expect(conversation.messages.outgoing.where.not(sender_type: 'User').count).to eq(0)
      expect(claim_status).to eq('completed')
    end

    it 'stops without Marine output when a handoff is already active (queued/in-flight job)' do
      Marine::Circuit::HandoffStateStore.new(conversation: conversation.reload).activate!(message_ids: [1])
      stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available }))

      described_class.perform_now(conversation, assistant, incoming.id)

      expect(conversation.messages.outgoing.where.not(sender_type: 'User').count).to eq(0)
      expect(claim_status).to eq('completed')
    end

    it 'announces a handoff once; a distinct later incoming message while active produces no further output' do
      stub_reasoning(product_payload(action: :handoff, reply: { kind: :unsupported }))
      described_class.perform_now(conversation, assistant, incoming.id)
      announced_count = conversation.messages.outgoing.count

      later = create(:message, conversation: conversation, message_type: :incoming, content: 'are you there?')
      described_class.perform_now(conversation, assistant, later.id)

      expect(conversation.messages.outgoing.count).to eq(announced_count)
    end

    it 'renders send_catalog as text-only clarification with no attachment when no usable catalog exists' do
      stub_reasoning(product_payload(
                       action: :send_catalog, reply: nil, operation: :update,
                       changes: { 'validated_family' => 'IMP', 'current_intent' => 'price', 'expected_attributes' => %w[size material] }
                     ))

      described_class.perform_now(conversation, assistant, incoming.id)

      reply = conversation.messages.outgoing.last
      expect(reply.content).to eq('Could you specify the size, material you need?')
      expect(reply.attachments).to be_empty
    end

    # --- Phase 6: native Product Catalog attachment delivery -------------------

    def usable_catalog(family: 'IMP')
      create(:marine_document, :product_catalog, assistant: assistant, product_family_code: family, status: :available)
    end

    def send_catalog_payload(operation: :start)
      product_payload(action: :send_catalog, reply: nil, operation: operation,
                      changes: { 'validated_family' => 'IMP', 'current_intent' => 'price', 'expected_attributes' => %w[size material] })
    end

    it 'delivers exactly one native attachment reusing the document blob and marks state only after message success' do
      document = usable_catalog
      stub_reasoning(send_catalog_payload)

      described_class.perform_now(conversation, assistant, incoming.id)

      reply = conversation.messages.outgoing.last
      expect(reply.content).to eq('Could you specify the size, material you need?')
      expect(reply.additional_attributes['source_type']).to eq('marine_product')
      expect(reply.attachments.count).to eq(1)
      expect(reply.attachments.first.file.blob.id).to eq(document.source_file.blob.id)

      state = product_state
      expect(state['catalog_sent']).to be(true)
      expect(state['catalog_document_id']).to eq(document.id)
      expect(state['catalog_message_id']).to eq(reply.id)
      expect(usage_count).to eq(1)
      expect(claim_status).to eq('completed')
    end

    it 'sends only text (no second attachment) when the flow has already sent a catalog' do
      document = usable_catalog
      store = Marine::Catalog::ProductFlowStateStore.new(conversation: conversation.reload)
      store.start!('validated_family' => 'IMP', 'current_intent' => 'price')
      store.update!('catalog_sent' => true, 'catalog_document_id' => document.id, 'catalog_message_id' => 987)
      stub_reasoning(send_catalog_payload(operation: :update))

      described_class.perform_now(conversation, assistant, incoming.id)

      reply = conversation.messages.outgoing.last
      expect(reply.content).to eq('Could you specify the size, material you need?')
      expect(reply.attachments).to be_empty
      expect(product_state['catalog_message_id']).to eq(987)
    end

    # --- Direct Product Catalog request (explicit "send me the catalog" intent) --

    def direct_catalog_payload(operation: :start)
      product_payload(action: :send_catalog,
                      reply: { kind: :catalog, family_code: 'IMP', family_name: 'Impeller' },
                      operation: operation, changes: { 'validated_family' => 'IMP', 'current_intent' => 'catalog' })
    end

    it 'delivers the native catalog with a direct-catalog caption for an explicit catalog request' do
      document = usable_catalog
      stub_reasoning(direct_catalog_payload)

      described_class.perform_now(conversation, assistant, incoming.id)

      reply = conversation.messages.outgoing.last
      expect(reply.content).to eq('Here is the product catalog for Impeller.')
      expect(reply.attachments.count).to eq(1)
      expect(reply.attachments.first.file.blob.id).to eq(document.source_file.blob.id)
      expect(product_state['catalog_sent']).to be(true)
    end

    it 'falls back to a deterministic no-catalog message (never a variant ask) when no catalog exists for a direct request' do
      stub_reasoning(direct_catalog_payload)

      described_class.perform_now(conversation, assistant, incoming.id)

      reply = conversation.messages.outgoing.last
      expect(reply.content).to eq("I'm sorry, I don't have a catalog available for Impeller right now.")
      expect(reply.attachments).to be_empty
    end

    # --- Customer-language localization of the product path (generic mechanism) ---

    def stub_language(language)
      allow(Marine::Llm::LanguageDetector).to receive(:new).and_return(
        instance_double(Marine::Llm::LanguageDetector, detect: { language: language, reliable: true, confidence: 1.0 })
      )
    end

    it 'localizes the direct-catalog caption into the customer language while keeping the selected attachment' do
      document = usable_catalog
      indo = create(:message, conversation: conversation, message_type: :incoming, content: 'boleh minta katalog impeller')
      stub_reasoning(direct_catalog_payload)
      stub_language('id')
      allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(
        instance_double(Marine::Llm::TranslateResponseService,
                        call: { ok: true, text: 'Ini katalog produk untuk Impeller.', translated: true })
      )
      # The translation is factually faithful (family preserved, token-clean): the localizer's
      # separate semantic validator accepts it, so it is delivered instead of falling back to English.
      allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(
        instance_double(Marine::Charge::FactPreservationValidator, valid?: true)
      )

      described_class.perform_now(conversation, assistant, indo.id)

      reply = conversation.messages.outgoing.last
      expect(reply.content).to eq('Ini katalog produk untuk Impeller.')
      # Translation must not alter document selection or one-catalog-per-flow behavior.
      expect(reply.attachments.count).to eq(1)
      expect(reply.attachments.first.file.blob.id).to eq(document.source_file.blob.id)
      expect(product_state['catalog_sent']).to be(true)
      expect(product_state['catalog_document_id']).to eq(document.id)
    end

    it 'leaves an English direct-catalog caption untranslated and skips the translator entirely' do
      document = usable_catalog
      english = create(:message, conversation: conversation, message_type: :incoming, content: 'please send me the impeller catalog')
      stub_reasoning(direct_catalog_payload)
      stub_language('en')
      expect(Marine::Llm::TranslateResponseService).not_to receive(:new)

      described_class.perform_now(conversation, assistant, english.id)

      reply = conversation.messages.outgoing.last
      expect(reply.content).to eq('Here is the product catalog for Impeller.')
      expect(reply.attachments.first.file.blob.id).to eq(document.source_file.blob.id)
    end

    it 'delivers the original English text when translation fails, never blocking the reply' do
      indo = create(:message, conversation: conversation, message_type: :incoming, content: 'berapa harga impeller')
      stub_reasoning(product_payload(
                       action: :send_catalog, reply: nil, operation: :update,
                       changes: { 'validated_family' => 'IMP', 'current_intent' => 'price', 'expected_attributes' => %w[size material] }
                     ))
      stub_language('id')
      # Simulate the translator degrading (unconfigured / error): it returns the original text.
      original = 'Could you specify the size, material you need?'
      allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(
        instance_double(Marine::Llm::TranslateResponseService, call: { ok: false, text: original, translated: false, error: 'x' })
      )

      described_class.perform_now(conversation, assistant, indo.id)

      expect(conversation.messages.outgoing.last.content).to eq(original)
    end

    # D7 — configured-language consistency with exact fact preservation on the real shared path.
    # A non-English product reply localizes through the SAME ReplyLocalizer + FactPlaceholderMask,
    # so immutable facts (variant code, currency, amount, UOM) stay byte-exact while the prose
    # follows the customer's language. The translator only ever sees the masked text (facts replaced
    # by opaque placeholders); no outbound network runs and exactly one message is delivered.
    it 'delivers a product price reply in the configured language with every fact byte-exact (masked, no LLM output trusted)' do
      msg = create(:message, conversation: conversation, message_type: :incoming, content: 'berapa harga IMP-3')
      payload = product_payload(
        action: :reply,
        reply: { kind: :price_available, variant_code: 'IMP-3', currency: 'IDR', price_list_rate: '150000', uom: 'pcs' },
        operation: :update,
        changes: { 'validated_family' => 'IMP', 'validated_variant' => 'IMP-3', 'current_intent' => 'price' }
      )
      payload['product_plan'][:language] = 'id' # per-turn provider language -> deterministic target
      stub_reasoning(payload)
      # Masking-aware translator: rephrases prose, leaves the opaque fact placeholders verbatim.
      allow(Marine::Llm::TranslateResponseService).to receive(:new) do |**kwargs|
        localized = kwargs[:text].gsub('The price for', 'Harga untuk').gsub(' is ', ' adalah ')
        instance_double(Marine::Llm::TranslateResponseService, call: { ok: true, text: localized, translated: true })
      end
      allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(
        instance_double(Marine::Charge::FactPreservationValidator, valid?: true)
      )

      described_class.perform_now(conversation, assistant, msg.id)

      reply = conversation.messages.outgoing.last
      expect(reply.content).to eq('Harga untuk IMP-3 adalah IDR 150000 per pcs.')
      expect(reply.content).to include('IMP-3', 'IDR', '150000', 'pcs') # immutable facts restored byte-exact
      expect(reply.attachments).to be_empty
      expect(conversation.messages.outgoing.count).to eq(1)
    end

    it 'rolls back flow state and leaves the claim retryable when catalog delivery fails' do
      usable_catalog
      stub_reasoning(send_catalog_payload)
      allow_any_instance_of(Marine::Conversation::ProductMessageDeliveryService).to receive(:call).and_raise(ActiveRecord::RecordInvalid)

      expect { described_class.perform_now(conversation, assistant, incoming.id) }.not_to raise_error
      expect(conversation.messages.outgoing.count).to eq(0)
      expect(product_state).to be_nil
      expect(usage_count).to eq(0)
      expect(claim_status).to eq('processing')
    end

    it 'delivers no catalog attachment when a newer relevant incoming message makes the job stale' do
      trigger = incoming
      create(:message, conversation: conversation, message_type: :incoming, content: 'actually never mind')
      usable_catalog
      baseline = conversation.messages.outgoing.count
      stub_reasoning(send_catalog_payload)

      described_class.perform_now(conversation, assistant, trigger.id)

      expect(conversation.messages.outgoing.count).to eq(baseline)
      expect(product_state).to be_nil
      expect(claim_status).to eq('completed')
    end

    it 'routes a product handoff plan through the existing Marine circuit handoff service' do
      stub_reasoning(product_payload(action: :handoff, reply: { kind: :unsupported }))
      handoff = instance_double(Marine::Circuit::HandoffService, perform: nil)
      expect(Marine::Circuit::HandoffService).to receive(:new)
        .with(hash_including(conversation: conversation, assistant: assistant, reason: 'product_unsupported')).and_return(handoff)

      described_class.perform_now(conversation, assistant, incoming.id)

      expect(claim_status).to eq('completed')
    end

    # --- Phase 3: clarification progression finalization -----------------------

    it 'applies returned clarification metadata only in finalization' do
      stub_reasoning(product_payload(
                       action: :clarify_variant, reply: { kind: :clarify_variant, attribute_names: %w[size] }, operation: :start,
                       changes: { 'validated_family' => 'IMP', 'current_intent' => 'variant_info',
                                  'expected_attributes' => %w[size], 'clarification_kind' => 'variant', 'clarification_count' => 1 }
                     ))

      described_class.perform_now(conversation, assistant, incoming.id)

      state = product_state
      expect(state['clarification_kind']).to eq('variant')
      expect(state['clarification_count']).to eq(1)
      expect(conversation.messages.outgoing.last.content).to eq('Could you specify the size you need?')
      expect(claim_status).to eq('completed')
    end

    it 'routes a third-occurrence clarification handoff through the existing HandoffService with a safe reason, once' do
      stub_reasoning(product_payload(action: :handoff, reply: { kind: :clarify_variant, attribute_names: %w[size] }))
      handoff = instance_double(Marine::Circuit::HandoffService, perform: nil)
      expect(Marine::Circuit::HandoffService).to receive(:new)
        .with(hash_including(conversation: conversation, assistant: assistant, reason: 'product_clarify_variant')).and_return(handoff)

      described_class.perform_now(conversation, assistant, incoming.id)

      expect(claim_status).to eq('completed')
    end

    it 'leaves an elapsed product flow untouched on a nonproduct RAG turn' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'product_flow_v1' => {
                             'version' => 3, 'flow_id' => 'stale', 'status' => 'active', 'expires_at' => 1.year.ago.iso8601,
                             'validated_family' => 'FAM-OLD', 'clarification_count' => 2, 'clarification_kind' => 'variant'
                           } } })
      stub_reasoning('response' => 'Our office is open 9-5.', 'action' => 'reply', 'agent_name' => 'Marine Bot',
                     'orchestration_path' => 'retrieval')

      described_class.perform_now(conversation, assistant, incoming.id)

      expect(conversation.messages.outgoing.last.content).to eq('Our office is open 9-5.')
      state = product_state
      expect(state['version']).to eq(3)
      expect(state['validated_family']).to eq('FAM-OLD')
      expect(state['clarification_count']).to eq(2)
    end

    # Regression — a non-substantive follow-up (e.g. a bare greeting) after an earlier product
    # exchange. A greeting is correctly routed to the RAG path (not_product), so it must NOT emit a
    # product/stock reply, and it must NOT wipe the validated product context — a genuine later
    # product follow-up may still resume it. Proves the trigger-bound job processes the exact
    # greeting turn while the persisted flow is preserved and no product message is created.
    it 'preserves an active validated product flow on a greeting RAG turn and emits no product reply' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'product_flow_v1' => {
                             'version' => 4, 'flow_id' => 'active', 'status' => 'active', 'expires_at' => 1.day.from_now.iso8601,
                             'validated_family' => 'FAM-1', 'validated_variant' => 'CHILD-1',
                             'current_intent' => 'stock', 'original_intent' => 'catalog'
                           } } })
      greeting = create(:message, conversation: conversation, message_type: :incoming, content: 'hello there')
      stub_reasoning('response' => 'How can I help you today?', 'action' => 'reply', 'agent_name' => 'Marine Bot',
                     'source_type' => 'llm_rag', 'orchestration_path' => 'retrieval', 'fallback_reason' => 'no_confident_cell_match')

      described_class.perform_now(conversation, assistant, greeting.id)

      reply = conversation.messages.outgoing.last
      expect(reply.content).to eq('How can I help you today?')
      expect(reply.additional_attributes['source_type']).to eq('llm_rag')
      expect(reply.additional_attributes['orchestration_path']).to eq('retrieval')
      # Validated product context retained for a genuine later product follow-up (a greeting is a
      # topic pause, not a reset of already-validated context).
      state = product_state
      expect(state['validated_family']).to eq('FAM-1')
      expect(state['validated_variant']).to eq('CHILD-1')
      expect(state['version']).to eq(4)
    end

    it 'creates a RAG reply with preserved metadata for a nonproduct payload' do
      stub_reasoning('response' => 'Our office is open 9-5.', 'action' => 'reply', 'agent_name' => 'Marine Bot',
                     'confidence' => 0.9, 'source_type' => 'manual', 'orchestration_path' => 'retrieval')

      described_class.perform_now(conversation, assistant, incoming.id)

      reply = conversation.messages.outgoing.last
      expect(reply.content).to eq('Our office is open 9-5.')
      expect(reply.additional_attributes['source_type']).to eq('manual')
      expect(reply.additional_attributes['confidence']).to eq(0.9)
      expect(claim_status).to eq('completed')
    end

    it 'rolls back product flow state and leaves the claim retryable when message creation fails' do
      stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available },
                                     operation: :update, changes: { 'validated_family' => 'IMP' }))
      allow_any_instance_of(described_class).to receive(:create_product_reply).and_raise(ActiveRecord::RecordInvalid)

      expect { described_class.perform_now(conversation, assistant, incoming.id) }.not_to raise_error
      expect(product_state).to be_nil
      expect(usage_count).to eq(0)
      expect(claim_status).to eq('processing')
    end

    it 'rolls back a partially completed handoff and leaves the claim retryable' do
      stub_reasoning(product_payload(action: :handoff, reply: { kind: :unsupported },
                                     operation: :update, changes: { 'validated_family' => 'IMP' }))
      allow_any_instance_of(Marine::Circuit::HandoffService).to receive(:perform) do
        conversation.messages.create!(message_type: :outgoing, private: true, account_id: conversation.account_id,
                                      inbox_id: conversation.inbox_id, sender: assistant, content: 'partial handoff note')
        raise ActiveRecord::RecordInvalid
      end

      expect { described_class.perform_now(conversation, assistant, incoming.id) }.not_to raise_error
      expect(conversation.messages.where(private: true).count).to eq(0)
      expect(product_state).to be_nil
      expect(claim_status).to eq('processing')
    end

    it 'is a safe no-op (no output, no claim) when the trigger id is not an incoming message' do
      outgoing = create(:message, conversation: conversation, message_type: :outgoing, sender: assistant)
      baseline = conversation.messages.count
      stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available }))

      described_class.perform_now(conversation, assistant, outgoing.id)

      expect(conversation.messages.reload.count).to eq(baseline)
      expect(outgoing.reload.additional_attributes).not_to have_key('wijaya_marine_ai')
    end

    it 'keeps legacy 2-arg behavior (no source, no claim) when the trigger id is nil' do
      chat = instance_double(Marine::Llm::AssistantChatService,
                             generate_response: { 'response' => 'legacy reply', 'action' => 'reply', 'agent_name' => 'Marine Bot' })
      expect(Marine::Llm::AssistantChatService).to receive(:new).with(assistant: assistant, conversation: conversation).and_return(chat)

      described_class.perform_now(conversation, assistant)

      expect(conversation.messages.outgoing.last.content).to eq('legacy reply')
      expect(incoming.reload.additional_attributes).not_to have_key('wijaya_marine_ai')
    end

    # --- Phase 6: fact-protected natural product wording -----------------------
    #
    # The deterministic localized reply stays the authoritative fallback. An eligible product
    # reply's wording candidate is precomputed (lock-free) and delivered ONLY when both the
    # deterministic checker and the semantic validator accept it; any rejection delivers the
    # exact deterministic response. send_catalog/handoff/excluded descriptors are never
    # naturalized. Here the wording service is stubbed to control accept/reject deterministically.
    describe 'natural product wording integration' do
      def stub_wording(result)
        service = instance_double(Marine::Catalog::GroundedProductWordingService, call: result)
        allow(Marine::Catalog::GroundedProductWordingService).to receive(:new).and_return(service)
        service
      end

      it 'replaces ONLY the product text with an accepted candidate, leaving state and metadata unchanged' do
        stub_reasoning(product_payload(
                         action: :reply, reply: { kind: :parent_info, family_code: 'IMP', family_name: 'Impeller' },
                         operation: :update, changes: { 'validated_family' => 'IMP', 'current_intent' => 'parent_info' }
                       ))
        stub_wording('About Impeller — which specific variant would you like?')

        described_class.perform_now(conversation, assistant, incoming.id)

        reply = conversation.messages.outgoing.last
        expect(reply.content).to eq('About Impeller — which specific variant would you like?')
        expect(reply.additional_attributes['source_type']).to eq('marine_product')
        expect(reply.additional_attributes['orchestration_path']).to eq('product')
        expect(reply.attachments).to be_empty
        expect(product_state['validated_family']).to eq('IMP')
        expect(usage_count).to eq(1)
        expect(claim_status).to eq('completed')
      end

      it 'delivers an accepted Tier 3 price candidate as the product text' do
        stub_reasoning(product_payload(
                         action: :reply,
                         reply: { kind: :price_available, variant_code: 'IMP-3', currency: 'IDR', price_list_rate: '150000', uom: 'pcs' },
                         operation: :update, changes: { 'validated_family' => 'IMP', 'validated_variant' => 'IMP-3', 'current_intent' => 'price' }
                       ))
        # A realistic candidate the real two-gate wording service could return: it names the
        # protected variant code (IMP-3) and preserves the exact amount/currency/UOM.
        stub_wording('IMP-3 is IDR 150000 per pcs.')

        described_class.perform_now(conversation, assistant, incoming.id)

        expect(conversation.messages.outgoing.last.content).to eq('IMP-3 is IDR 150000 per pcs.')
        expect(product_state['validated_variant']).to eq('IMP-3')
      end

      it 'returns the exact deterministic localized response when wording is rejected' do
        stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available },
                                       operation: :update, changes: { 'validated_family' => 'IMP', 'current_intent' => 'stock' }))
        stub_wording(nil)

        described_class.perform_now(conversation, assistant, incoming.id)

        expect(conversation.messages.outgoing.last.content).to eq('Good news — that item is currently in stock.')
      end

      it 'prepares wording from the ContextBuilder bounded trigger/history, exact localized fallback, and opening state' do
        captured = {}
        service = instance_double(Marine::Catalog::GroundedProductWordingService)
        allow(service).to receive(:call) do |args|
          captured.merge!(args)
          'In stock right now.'
        end
        allow(Marine::Catalog::GroundedProductWordingService).to receive(:new).and_return(service)
        stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available },
                                       operation: :update, changes: { 'validated_family' => 'IMP', 'current_intent' => 'stock' }))

        described_class.perform_now(conversation, assistant, incoming.id)

        expect(captured[:action]).to eq(:reply)
        expect(captured[:descriptor][:kind]).to eq(:stock_available)
        expect(captured[:customer_request]).to eq('price for impeller 3 inch') # the bounded trigger content
        expect(captured[:message_history]).to eq([]) # only the trigger exists; no prior public turns
        # the EXACT deterministic localized fallback is passed as the sole factual authority
        expect(captured[:fallback]).to eq('Good news — that item is currently in stock.')
        expect(captured[:opening]).to be(true) # no earlier Marine reply -> Phase 2 opening turn
        expect(conversation.messages.outgoing.last.content).to eq('In stock right now.')
      end

      it 'delivers deterministic content with no re-localization under the finalize lock when wording generation fails' do
        # The eligible path is already committed, so a wording-service failure retains the exact
        # localized fallback computed lock-free; delivery uses it verbatim with NO second
        # ReplyLocalizer call (which would be a network call under the finalize row lock).
        localizer_calls = 0
        allow(Marine::Catalog::ReplyLocalizer).to receive(:new).and_wrap_original do |method, **kwargs|
          localizer_calls += 1
          method.call(**kwargs)
        end
        raising = instance_double(Marine::Catalog::GroundedProductWordingService)
        allow(raising).to receive(:call).and_raise(StandardError, 'boom')
        allow(Marine::Catalog::GroundedProductWordingService).to receive(:new).and_return(raising)
        stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available },
                                       operation: :update, changes: { 'validated_family' => 'IMP', 'current_intent' => 'stock' }))

        described_class.perform_now(conversation, assistant, incoming.id)

        expect(conversation.messages.outgoing.last.content).to eq('Good news — that item is currently in stock.')
        expect(localizer_calls).to eq(1) # only the single lock-free precompute; delivery did not re-localize
        expect(claim_status).to eq('completed')
      end

      it 'falls back to deterministic English with no further network call when localization itself fails during preparation' do
        # Localization raising before any localized fallback exists: preparation degrades to the
        # deterministic English reply (the exact text ReplyLocalizer itself returns on failure) and
        # never retries an LLM/network path under the finalize lock. The wording service is never
        # even constructed (the failure precedes it).
        call_count = 0
        allow(Marine::Catalog::ReplyLocalizer).to receive(:new) do
          call_count += 1
          raise StandardError, 'boom' if call_count == 1

          instance_double(Marine::Catalog::ReplyLocalizer, call: 'SHOULD NOT BE USED') # a re-localization would use this
        end
        expect(Marine::Catalog::GroundedProductWordingService).not_to receive(:new)
        stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available },
                                       operation: :update, changes: { 'validated_family' => 'IMP', 'current_intent' => 'stock' }))

        described_class.perform_now(conversation, assistant, incoming.id)

        expect(conversation.messages.outgoing.last.content).to eq('Good news — that item is currently in stock.')
        expect(call_count).to eq(1) # localization attempted once (raised); never retried under the lock
        expect(claim_status).to eq('completed')
      end

      it 'precomputes wording before the finalize staleness gate but delivers nothing when the job is stale' do
        trigger = incoming
        create(:message, conversation: conversation, message_type: :incoming, content: 'actually never mind')
        baseline = conversation.messages.outgoing.count
        service = stub_wording('In stock right now.')
        stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available },
                                       operation: :update, changes: { 'validated_family' => 'IMP', 'current_intent' => 'stock' }))

        described_class.perform_now(conversation, assistant, trigger.id)

        expect(service).to have_received(:call) # prepared before the lock/staleness gate
        expect(conversation.messages.outgoing.count).to eq(baseline) # stale: not delivered
        expect(product_state).to be_nil
      end

      it 'does not localize or transform the accepted candidate a second time' do
        localizer_calls = 0
        allow(Marine::Catalog::ReplyLocalizer).to receive(:new).and_wrap_original do |method, **kwargs|
          localizer_calls += 1
          method.call(**kwargs)
        end
        stub_reasoning(product_payload(action: :reply, reply: { kind: :stock_available },
                                       operation: :update, changes: { 'validated_family' => 'IMP', 'current_intent' => 'stock' }))
        stub_wording('In stock right now.')

        described_class.perform_now(conversation, assistant, incoming.id)

        expect(conversation.messages.outgoing.last.content).to eq('In stock right now.')
        expect(localizer_calls).to eq(1) # only the single precompute localization; no re-localization at delivery
      end

      it 'never invokes product wording on a send_catalog turn' do
        stub_reasoning(product_payload(
                         action: :send_catalog, reply: nil, operation: :update,
                         changes: { 'validated_family' => 'IMP', 'current_intent' => 'price', 'expected_attributes' => %w[size material] }
                       ))
        expect(Marine::Catalog::GroundedProductWordingService).not_to receive(:new)

        described_class.perform_now(conversation, assistant, incoming.id)

        expect(conversation.messages.outgoing.last.content).to eq('Could you specify the size, material you need?')
      end

      it 'never invokes product wording on a product handoff turn' do
        stub_reasoning(product_payload(action: :handoff, reply: { kind: :unsupported }))
        allow(Marine::Circuit::HandoffService).to receive(:new).and_return(instance_double(Marine::Circuit::HandoffService, perform: nil))
        expect(Marine::Catalog::GroundedProductWordingService).not_to receive(:new)

        described_class.perform_now(conversation, assistant, incoming.id)
      end

      it 'leaves the deliberately excluded price_unavailable descriptor deterministic-only' do
        stub_reasoning(product_payload(action: :reply, reply: { kind: :price_unavailable },
                                       operation: :update, changes: { 'validated_family' => 'IMP', 'current_intent' => 'price' }))
        expect(Marine::Catalog::GroundedProductWordingService).not_to receive(:new)

        described_class.perform_now(conversation, assistant, incoming.id)

        expect(conversation.messages.outgoing.last.content).to eq("I'm sorry, I don't have the price for that item right now.")
      end
    end
  end

  describe '#perform (legacy 2-arg path — canonical bounded context, no product flow)' do
    let(:conversation) { create(:conversation) }
    let(:assistant) { create(:marine_assistant, account: conversation.account) }
    let(:base) { Time.zone.parse('2026-06-01 09:00:00') }

    def add(type, at:, content:, sender: nil)
      create(:message, conversation: conversation, message_type: type, content: content, sender: sender, created_at: at)
    end

    it 'supplies the latest incoming as a separate bounded trigger, bounded chronological history, and no source' do
      add(:incoming, at: base + 1, content: 'first question')
      add(:outgoing, at: base + 2, sender: assistant, content: 'earlier marine answer')
      add(:incoming, at: base + 3, content: 'x' * 600) # truncated to 500 chars in history
      add(:incoming, at: base + 4, content: 'latest question') # the trigger

      init_args = nil
      call_args = nil
      chat = instance_double(Marine::Llm::AssistantChatService)
      allow(Marine::Llm::AssistantChatService).to receive(:new) do |**kwargs|
        init_args = kwargs
        chat
      end
      allow(chat).to receive(:generate_response) do |**kwargs|
        call_args = kwargs
        { 'response' => 'ok', 'action' => 'reply', 'agent_name' => 'Marine Bot' }
      end

      described_class.perform_now(conversation, assistant)

      # No `source:` is passed, so Agent::Runner's product_payload stays disabled: no Product Flow.
      expect(init_args).to eq(assistant: assistant, conversation: conversation)
      expect(init_args).not_to have_key(:source)

      # Latest incoming is the trigger, supplied separately exactly once.
      expect(call_args[:additional_message]).to eq('latest question')

      # Earlier context is chronological and bounded (500 chars/turn); trigger absent from history.
      expect(call_args[:message_history]).to eq(
        [{ role: 'user', content: 'first question' },
         { role: 'assistant', content: 'earlier marine answer' },
         { role: 'user', content: 'x' * 500 }]
      )
      expect(call_args[:message_history].map { |h| h[:content] }).not_to include('latest question')
    end
  end
end
