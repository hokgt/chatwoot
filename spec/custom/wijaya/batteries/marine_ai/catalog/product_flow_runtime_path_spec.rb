# frozen_string_literal: true

require 'rails_helper'

# Full runtime-path regression for the deterministic Marine product flow.
#
# Unlike the component specs (which stub the reasoning payload), this exercises the REAL
# chain end-to-end through Marine::Conversation::ResponseBuilderJob#perform_now:
#   IntentExtractor (real parse/normalize) -> ProductQueryOrchestrator (real planning +
#   data-driven family recovery) -> ProductFlowStateStore (real apply) ->
#   ProductCatalogSelector + ProductMessageDeliveryService (real native delivery) ->
#   ReplyLocalizer (real).
#
# Only the true external boundaries are stubbed: the LLM provider (Marine::Llm::BaseService),
# the CLD3 language detector, and outbound delivery (ActiveJob test adapter). The families
# are GENERIC SYNTHETIC MULTI-WORD names, and the provider fixture deliberately returns a
# NOISY family candidate that does not resolve on its own, while the raw synthetic turn
# carries only a PARTIAL token of one multi-word family name (a single one of its words) —
# exactly the case a whole-name match would miss, proving the partial recovery closes it and
# still fails closed when the partial token is shared/unmatched. The provider also returns a
# customer-language code that must win over a deliberately wrong CLD3 result, with no second
# provider call. No real product names, customer text, or per-language phrase lists appear.
RSpec.describe 'Marine product flow full runtime path', type: :model do
  include ActiveJob::TestHelper

  # A minimal read-only stand-in for the catalog family repository: exact match on
  # code/name, and a bounded substring active-candidate search — the same shape the real
  # repository exposes, over generic fake rows (never real product data).
  class FakeMarineFamilyRepository
    def initialize(rows)
      @rows = rows.map { |row| { code: row[:code], name: row[:name] } }
    end

    def resolve_exact(identifier)
      value = identifier.to_s.strip
      return nil if value.empty?

      matches = @rows.select { |row| row[:code].casecmp?(value) || row[:name].casecmp?(value) }
      matches.length == 1 ? matches.first : nil
    end

    def active_candidates(query: nil, limit: 20)
      needle = query.to_s.strip.downcase
      rows = if needle.empty?
               @rows
             else
               @rows.select { |row| row[:code].downcase.include?(needle) || row[:name].downcase.include?(needle) }
             end
      rows.first(limit)
    end
  end

  let(:conversation) { create(:conversation) }
  let(:assistant) { create(:marine_assistant, account: conversation.account) }
  let(:trigger) { create(:message, conversation: conversation, message_type: :incoming, content: turn_text) }

  # Generic fake MULTI-WORD families: recovered (Coastal Alpha Series), the stale active
  # family (Harbor Bravo Line), and a decoy (Reef Charlie Range). None share a word, so a
  # single distinctive word of one name recovers exactly that family.
  let(:family_rows) do
    [{ code: 'FAM-CAT', name: 'Coastal Alpha Series' },
     { code: 'FAM-OLD', name: 'Harbor Bravo Line' },
     { code: 'FAM-X', name: 'Reef Charlie Range' }]
  end
  let(:family_repository) { FakeMarineFamilyRepository.new(family_rows) }

  # Provider fixture: a NOISY mention that resolves to nothing on its own, plus a customer
  # language code. The turn text carries only ONE word ("Alpha") of the multi-word family
  # name, which recovers exactly one family.
  let(:turn_text) { 'Please send Alpha catalog now' }
  let(:customer_language) { 'id' }
  let(:intent_json) do
    { product_related: true, intent: 'catalog',
      family_mention: 'product catalog', customer_language: customer_language }.to_json
  end
  # A distinct follow-up turn (scenario D): a continuation catalog request that names no
  # family and does not change families. Carries the marker word "resend" so the provider
  # stub returns this fixture for the second extraction only.
  let(:follow_up_text) { 'Kindly resend the catalog document' }
  let(:follow_up_intent_json) do
    { product_related: true, intent: 'catalog',
      family_mention: nil, customer_language: 'id' }.to_json
  end
  let(:provider_calls) { [] }
  let(:base_service) { instance_double(Marine::Llm::BaseService, configured?: true) }

  # Deterministic translation marker (neutral synthetic string, never a language phrase map).
  TRANSLATED_MARKER = 'LOCALIZED_REPLY'

  before do
    # Repository boundary: inject the fake family repo the orchestrator builds by default.
    allow(Marine::Catalog::ProductFamilyRepository).to receive(:new).and_return(family_repository)

    # Provider boundary: one stub serves the intent extraction, the follow-up extraction,
    # and the translation, branching on the system prompt / customer message. NO second
    # provider call is made purely for language.
    allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
    allow(base_service).to receive(:complete) do |prompt:, system: nil|
      provider_calls << { prompt: prompt.to_s, system: system.to_s }
      if system.to_s.include?('translator')
        { ok: true, message: TRANSLATED_MARKER, error: nil }
      elsif prompt.to_s.include?('resend')
        { ok: true, message: follow_up_intent_json, error: nil }
      else
        { ok: true, message: intent_json, error: nil }
      end
    end

    clear_enqueued_jobs
    clear_performed_jobs
  end

  # A deliberately WRONG CLD3 classification (models the observed jv misclassification).
  def stub_cld3(language)
    result = double('cld3_result')
    allow(result).to receive_messages(language: language, probability: 0.958, 'reliable?': true)
    identifier = instance_double(CLD3::NNetLanguageIdentifier, find_language: result)
    allow(CLD3::NNetLanguageIdentifier).to receive(:new).and_return(identifier)
  end

  def usable_catalog(family_code)
    create(:marine_document, :product_catalog, assistant: assistant,
                                               product_family_code: family_code, status: :available)
  end

  # Seed a stale ACTIVE flow (different family + already-sent catalog markers).
  def seed_stale_flow!
    store = Marine::Catalog::ProductFlowStateStore.new(conversation: conversation.reload)
    store.start!('validated_family' => 'FAM-OLD', 'current_intent' => 'catalog')
    store.update!('catalog_sent' => true, 'catalog_document_id' => 111, 'catalog_message_id' => 222)
  end

  def product_state
    Marine::Catalog::ProductFlowStateStore.new(conversation: conversation.reload).current
  end

  def claim_status_for(message)
    message.reload.additional_attributes.dig('wijaya_marine_ai', 'processing_claim_v1', 'status')
  end

  def usage_count
    conversation.account.reload.custom_attributes['marine_responses_usage'].to_i
  end

  def translation_calls
    provider_calls.select { |call| call[:system].include?('translator') }
  end

  describe 'the full trigger-bound catalog turn' do
    it 'recovers the family from a partial turn token, delivers one native catalog, switches the flow, and localizes via the provider language' do
      document = usable_catalog('FAM-CAT')
      seed_stale_flow!
      stub_cld3('jv') # wrong CLD3 result that must be overridden by the provider language

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, trigger.id)

      reply = conversation.messages.reload.outgoing.last
      # One outgoing catalog message reusing the exact existing blob — no new blob.
      expect(conversation.messages.outgoing.count).to eq(1)
      expect(reply.attachments.count).to eq(1)
      expect(reply.attachments.first.file.blob.id).to eq(document.source_file.blob.id)

      # Row-derived family persisted; stale active flow (and its catalog markers) replaced.
      state = product_state
      expect(state['validated_family']).to eq('FAM-CAT')
      expect(state['catalog_sent']).to be(true)
      expect(state['catalog_document_id']).to eq(document.id)
      expect(state['catalog_message_id']).to eq(reply.id)
      expect(state['catalog_document_id']).not_to eq(111)

      # Provider language (id) wins over the wrong CLD3 result (jv), with no extra call.
      expect(reply.content).to eq(TRANSLATED_MARKER)
      expect(translation_calls.length).to eq(1)
      expect(translation_calls.first[:system]).to include('to id')
      expect(translation_calls.first[:system]).not_to include('to jv')

      # No outbound send job executed and no external (non-localhost) network was touched.
      expect(performed_jobs).to be_empty
      expect(a_request(:any, %r{\Ahttps?://(?!(localhost|127\.0\.0\.1))}i)).not_to have_been_made

      expect(usage_count).to eq(1)
      expect(claim_status_for(trigger)).to eq('completed')
    end

    it 'creates no second attachment when the same incoming message is delivered twice' do
      usable_catalog('FAM-CAT')
      seed_stale_flow!
      stub_cld3('jv')

      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, trigger.id)
      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, trigger.id)

      expect(conversation.messages.outgoing.count).to eq(1)
      expect(conversation.messages.outgoing.last.attachments.count).to eq(1)
      expect(usage_count).to eq(1)
    end

    it 'reuses the active validated family on a DISTINCT follow-up turn without re-sending or switching' do
      document = usable_catalog('FAM-CAT')
      seed_stale_flow!
      stub_cld3('jv')

      # First turn: recover + deliver the native catalog for FAM-CAT.
      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, trigger.id)
      first_reply = conversation.messages.reload.outgoing.last
      expect(first_reply.attachments.count).to eq(1)

      # A genuinely NEW incoming follow-up message (never a replay of the same one).
      follow_up = create(:message, conversation: conversation, message_type: :incoming, content: follow_up_text)
      Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, follow_up.id)

      second_reply = conversation.messages.reload.outgoing.last
      expect(second_reply.id).not_to eq(first_reply.id)

      # Reuses the active family; no clarification, no second catalog attachment/blob.
      expect(conversation.messages.outgoing.count).to eq(2)
      expect(second_reply.attachments).to be_empty
      expect(conversation.messages.outgoing.sum { |m| m.attachments.count }).to eq(1)

      # The existing already-shared response, emitted THROUGH localization (provider id).
      expect(second_reply.content).to eq(TRANSLATED_MARKER)
      expect(translation_calls.length).to eq(2)
      expect(translation_calls.last[:system]).to include('to id')

      # Catalog document/message markers are preserved (same family, same one catalog).
      state = product_state
      expect(state['validated_family']).to eq('FAM-CAT')
      expect(state['catalog_sent']).to be(true)
      expect(state['catalog_document_id']).to eq(document.id)
      expect(state['catalog_message_id']).to eq(first_reply.id)

      # Both distinct incoming messages completed their own claim.
      expect(claim_status_for(trigger)).to eq('completed')
      expect(claim_status_for(follow_up)).to eq('completed')
      expect(usage_count).to eq(2)
    end

    context 'when the provider returns a BLANK family mention on an active different-family flow' do
      # The real continuation bug: with family_mention nil the extractor's family_changed? is
      # false, so the orchestrator would silently reuse the stale active family (FAM-OLD, which
      # has no catalog). Only the raw turn's partial token ("Alpha") names a DIFFERENT active
      # family — it must be treated as a genuine switch.
      let(:intent_json) do
        { product_related: true, intent: 'catalog',
          family_mention: nil, customer_language: customer_language }.to_json
      end

      it 'treats the unique raw-turn family as a switch: fresh flow, one native catalog, stale markers replaced, localized' do
        document = usable_catalog('FAM-CAT')
        seed_stale_flow!
        stub_cld3('jv')

        Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, trigger.id)

        reply = conversation.messages.reload.outgoing.last
        # One outgoing catalog reusing the exact existing blob — no new blob.
        expect(conversation.messages.outgoing.count).to eq(1)
        expect(reply.attachments.count).to eq(1)
        expect(reply.attachments.first.file.blob.id).to eq(document.source_file.blob.id)

        # Switched to the row-derived family via a fresh :start flow, replacing the stale
        # active family AND all of its catalog markers: catalog_document_id now equals the
        # freshly delivered document (never the seeded stale marker) via a :start, not :update.
        state = product_state
        expect(state['validated_family']).to eq('FAM-CAT')
        expect(state['catalog_sent']).to be(true)
        expect(state['catalog_document_id']).to eq(document.id)
        expect(state['catalog_message_id']).to eq(reply.id)

        # Provider language (id) wins over the wrong CLD3 result (jv), with no extra call.
        expect(reply.content).to eq(TRANSLATED_MARKER)
        expect(translation_calls.length).to eq(1)
        expect(translation_calls.first[:system]).to include('to id')
        expect(translation_calls.first[:system]).not_to include('to jv')

        # No outbound send job and no external (non-localhost) network was touched.
        expect(performed_jobs).to be_empty
        expect(a_request(:any, %r{\Ahttps?://(?!(localhost|127\.0\.0\.1))}i)).not_to have_been_made

        expect(usage_count).to eq(1)
        expect(claim_status_for(trigger)).to eq('completed')
      end
    end

    context 'when a partial token is shared by two multi-word families' do
      # Two active multi-word families SHARE the word "Coastal"; the turn carries only that
      # shared partial token, so recovery must fail closed rather than guess between them.
      let(:family_rows) do
        [{ code: 'FAM-CAT', name: 'Coastal Alpha Series' },
         { code: 'FAM-OLD', name: 'Coastal Bravo Line' },
         { code: 'FAM-X', name: 'Reef Charlie Range' }]
      end
      let(:turn_text) { 'Please send Coastal catalog now' }
      let(:customer_language) { 'en' }

      it 'clarifies without a catalog and never switches the active flow' do
        usable_catalog('FAM-CAT')
        seed_stale_flow!
        stub_cld3('jv')

        Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, trigger.id)

        reply = conversation.messages.reload.outgoing.last
        expect(reply.attachments).to be_empty
        expect(reply.content).to eq('Could you tell me which product you are interested in?')
        # Ambiguity must not corrupt the pre-existing flow.
        expect(product_state['validated_family']).to eq('FAM-OLD')
        expect(product_state['catalog_document_id']).to eq(111)
      end
    end

    context 'when the partial token matches no family' do
      let(:turn_text) { 'Please send Zeta catalog now' }
      let(:customer_language) { 'en' }

      it 'clarifies without a catalog and never switches the active flow' do
        usable_catalog('FAM-CAT')
        seed_stale_flow!
        stub_cld3('jv')

        Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, trigger.id)

        reply = conversation.messages.reload.outgoing.last
        expect(reply.attachments).to be_empty
        expect(reply.content).to eq('Could you tell me which product you are interested in?')
        expect(product_state['validated_family']).to eq('FAM-OLD')
        expect(product_state['catalog_document_id']).to eq(111)
      end
    end

    context 'when the provider language is missing/malformed' do
      let(:customer_language) { '!!not-a-language!!' }

      it 'still delivers the catalog and degrades safely to the untranslated English caption' do
        document = usable_catalog('FAM-CAT')
        seed_stale_flow!
        # Local detection unavailable/erroring -> unknown -> no translation, delivery preserved.
        failing = instance_double(CLD3::NNetLanguageIdentifier)
        allow(failing).to receive(:find_language).and_raise(StandardError, 'boom')
        allow(CLD3::NNetLanguageIdentifier).to receive(:new).and_return(failing)

        Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, trigger.id)

        reply = conversation.messages.reload.outgoing.last
        expect(reply.content).to eq('Here is the product catalog for Coastal Alpha Series.')
        expect(reply.attachments.first.file.blob.id).to eq(document.source_file.blob.id)
        expect(translation_calls).to be_empty
        expect(product_state['validated_family']).to eq('FAM-CAT')
      end
    end

    context 'when the customer turn is English (source language)' do
      let(:customer_language) { 'en' }

      it 'delivers the catalog and bypasses translation entirely' do
        document = usable_catalog('FAM-CAT')
        seed_stale_flow!
        stub_cld3('jv') # must never be consulted: provider says English

        Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, trigger.id)

        reply = conversation.messages.reload.outgoing.last
        expect(reply.content).to eq('Here is the product catalog for Coastal Alpha Series.')
        expect(reply.attachments.first.file.blob.id).to eq(document.source_file.blob.id)
        expect(translation_calls).to be_empty
        expect(product_state['validated_family']).to eq('FAM-CAT')
      end
    end
  end

  # --- Focused unit coverage of the two mechanisms (no provider, no network) -----------

  describe Marine::Catalog::ProductQueryOrchestrator do
    let(:extractor) { instance_double(Marine::Catalog::IntentExtractor) }
    let(:orchestrator) do
      described_class.new(repositories: { family: family_repository }, intent_extractor: extractor)
    end

    it 'recovers a single row-derived family from a partial turn token and propagates the language, on a fresh flow' do
      allow(extractor).to receive(:extract).and_return(
        product_related: true, intent: 'catalog', family_mention: 'product catalog',
        customer_language: 'id', family_changed: false
      )

      plan = orchestrator.process(text: 'Please send Alpha catalog now', context: [], flow: nil)

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-CAT', family_name: 'Coastal Alpha Series')
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to include('validated_family' => 'FAM-CAT', 'current_intent' => 'catalog')
      expect(plan[:language]).to eq('id')
    end

    it 'fails closed to clarify_family when the raw turn is ambiguous across families' do
      allow(extractor).to receive(:extract).and_return(
        product_related: true, intent: 'catalog', family_mention: 'product catalog'
      )

      plan = orchestrator.process(text: 'Please send Alpha and Bravo now', context: [], flow: nil)

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:state]).to eq(operation: :none, changes: {})
    end

    # Continuation cases: an ACTIVE flow with a blank/unchanged mention, where only the raw
    # turn carries family evidence. A string-keyed active flow snapshot on a stale family.
    def continuation_flow(validated_family)
      { 'version' => 2, 'flow_id' => 'flow-1', 'status' => 'active',
        'expires_at' => '2999-01-01T00:00:00Z', 'expected_attributes' => [],
        'validated_family' => validated_family, 'current_intent' => 'catalog',
        'catalog_sent' => true }
    end

    it 'switches to a unique DIFFERENT active family named only by the raw turn (:start)' do
      allow(extractor).to receive(:extract).and_return(
        product_related: true, intent: 'catalog', family_mention: nil,
        customer_language: 'id', family_changed: false
      )

      plan = orchestrator.process(text: 'Please send Alpha catalog now', context: [], flow: continuation_flow('FAM-OLD'))

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-CAT', family_name: 'Coastal Alpha Series')
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to include('validated_family' => 'FAM-CAT', 'current_intent' => 'catalog')
    end

    it 'continues and revalidates the active family when the raw turn carries no family evidence (:update)' do
      allow(extractor).to receive(:extract).and_return(
        product_related: true, intent: 'catalog', family_mention: nil, family_changed: false
      )

      plan = orchestrator.process(text: 'Kindly resend the catalog document', context: [], flow: continuation_flow('FAM-OLD'))

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-OLD', family_name: 'Harbor Bravo Line')
      expect(plan[:state][:operation]).to eq(:update)
    end

    it 'fails closed to clarify_family (no switch, no state change) when the raw turn is ambiguous on an active flow' do
      allow(extractor).to receive(:extract).and_return(
        product_related: true, intent: 'catalog', family_mention: nil, family_changed: false
      )

      plan = orchestrator.process(text: 'Please send Alpha and Bravo now', context: [], flow: continuation_flow('FAM-OLD'))

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:state]).to eq(operation: :none, changes: {})
    end

    it 'keeps the active family (:update) when the extracted mention resolves to it, ignoring an incidental raw token for another family' do
      allow(extractor).to receive(:extract).and_return(
        product_related: true, intent: 'catalog', family_mention: 'Harbor Bravo Line',
        customer_language: 'id', family_changed: false
      )

      # The raw turn's "Alpha" token names a DIFFERENT active family, but the exactly-resolved
      # extracted mention (the active family) wins: continue and revalidate it, never clarify.
      plan = orchestrator.process(text: 'Please send Alpha catalog now', context: [], flow: continuation_flow('FAM-OLD'))

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-OLD', family_name: 'Harbor Bravo Line')
      expect(plan[:state][:operation]).to eq(:update)
    end

    it 'keeps the active family (:update, no re-delivery) when a NONBLANK mention re-resolves to it even though family_changed is set' do
      allow(extractor).to receive(:extract).and_return(
        product_related: true, intent: 'catalog', family_mention: 'Harbor Bravo Line',
        customer_language: 'id', family_changed: true
      )

      # family_changed? is string inequality against the flow code, so a re-mention of the
      # SAME canonical family can still set it true. Continuation is recomputed from canonical
      # identity + active-flow preconditions, NOT that flag: continue and revalidate the active
      # family (:update), never a spurious :start that would clear markers and duplicate the
      # catalog.
      plan = orchestrator.process(text: 'Please send catalog now', context: [], flow: continuation_flow('FAM-OLD'))

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-OLD', family_name: 'Harbor Bravo Line')
      expect(plan[:state][:operation]).to eq(:update)
    end

    it 'starts a fresh flow (:start) when the resolved mention matches a validated family carried by an INACTIVE flow' do
      allow(extractor).to receive(:extract).and_return(
        product_related: true, intent: 'catalog', family_mention: 'Harbor Bravo Line',
        customer_language: 'id', family_changed: false
      )

      # Defensive: bare same_family? alone would wrongly continue a terminated flow's stale
      # family. An inactive flow fails the active-flow precondition, so the resolved mention
      # opens a fresh :start flow instead of resurrecting the dead one.
      inactive_flow = continuation_flow('FAM-OLD').merge('status' => 'expired')
      plan = orchestrator.process(text: 'Please send catalog now', context: [], flow: inactive_flow)

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-OLD', family_name: 'Harbor Bravo Line')
      expect(plan[:state][:operation]).to eq(:start)
    end

    it 'switches to the exactly-resolved DIFFERENT extracted family (:start), ignoring an incidental raw token for a third family' do
      allow(extractor).to receive(:extract).and_return(
        product_related: true, intent: 'catalog', family_mention: 'Coastal Alpha Series',
        customer_language: 'id', family_changed: false
      )

      # The raw turn's "Charlie" token names yet another active family; the exactly-resolved
      # extracted family wins over both the stale flow and the incidental raw token.
      plan = orchestrator.process(text: 'Please send Charlie catalog now', context: [], flow: continuation_flow('FAM-OLD'))

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'FAM-CAT', family_name: 'Coastal Alpha Series')
      expect(plan[:state][:operation]).to eq(:start)
      expect(plan[:state][:changes]).to include('validated_family' => 'FAM-CAT', 'current_intent' => 'catalog')
    end
  end

  describe Marine::Catalog::ReplyLocalizer do
    it 'prefers the bounded provider language over the local detector and never consults CLD3' do
      expect(CLD3::NNetLanguageIdentifier).not_to receive(:new)
      translator = instance_double(Marine::Llm::TranslateResponseService,
                                   call: { ok: true, text: TRANSLATED_MARKER, translated: true })
      expect(Marine::Llm::TranslateResponseService).to receive(:new)
        .with(text: 'Here is the catalog.', target_language: 'id', source_language: 'en', account: nil)
        .and_return(translator)

      result = described_class.new(text: 'Here is the catalog.', trigger_text: 'anything',
                                   provider_language: 'id').call

      expect(result).to eq(TRANSLATED_MARKER)
    end

    it 'falls back to local detection when the provider language is malformed' do
      allow(Marine::Llm::LanguageDetector).to receive(:new).and_return(
        instance_double(Marine::Llm::LanguageDetector, detect: { language: 'unknown', reliable: false, confidence: 0.0 })
      )
      expect(Marine::Llm::TranslateResponseService).not_to receive(:new)

      result = described_class.new(text: 'Here is the catalog.', trigger_text: 'short',
                                   provider_language: 'not-a-lang!!').call

      expect(result).to eq('Here is the catalog.')
    end
  end
end
