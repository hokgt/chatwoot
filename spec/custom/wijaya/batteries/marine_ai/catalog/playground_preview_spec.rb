# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::PlaygroundPreview do
  subject(:preview) { described_class.new(assistant: assistant, account: account) }

  let(:account) { instance_double(Account) }
  let(:assistant) { double('assistant', name: 'Marine Bot', config: { 'language' => 'id' }) }
  let(:orchestrator) { instance_double(Marine::Catalog::ProductQueryOrchestrator) }
  let(:localizer) { instance_double(Marine::Catalog::ReplyLocalizer) }
  let(:selector) { instance_double(Marine::Documents::ProductCatalogSelector) }
  let(:token_signer) { instance_double(Marine::Catalog::PlaygroundStateToken) }
  let(:renderer) { Marine::Catalog::ReplyRenderer.new }

  def plan(action:, reply: nil, operation: :none, changes: {}, language: 'id', handoff_category: nil) # rubocop:disable Metrics/ParameterLists
    { action: action, reply: reply, state: { operation: operation, changes: changes },
      language: language, handoff_category: handoff_category }
  end

  before do
    allow(Marine::Catalog::ProductQueryOrchestrator).to receive(:new).and_return(orchestrator)
    # Localization echoes the deterministic English it was given so assertions can read it back;
    # the real ReplyLocalizer already fails closed to English, so this mirrors its safe default.
    allow(Marine::Catalog::ReplyLocalizer).to receive(:new) do |**kwargs|
      @localized_english = kwargs[:text]
      localizer
    end
    allow(localizer).to receive(:call) { @localized_english }
    allow(Marine::Documents::ProductCatalogSelector).to receive(:new).and_return(selector)
    allow(selector).to receive(:call).and_return(nil)
    # State token: opaque signer stubbed so the unit test controls decode and inspects encode.
    allow(Marine::Catalog::PlaygroundStateToken).to receive(:new).and_return(token_signer)
    allow(token_signer).to receive(:decode).and_return(nil)
    allow(token_signer).to receive(:encode) { |snapshot| snapshot.present? ? 'signed-token' : nil }
  end

  describe 'non-product and blank turns fall through to RAG (nil)' do
    it 'returns nil for a not_product plan' do
      allow(orchestrator).to receive(:process).and_return(plan(action: :not_product))
      expect(preview.call(query: 'selamat pagi', history: [])).to be_nil
    end

    it 'returns nil for a blank query without calling the orchestrator' do
      expect(orchestrator).not_to receive(:process)
      expect(preview.call(query: '   ', history: [])).to be_nil
    end
  end

  describe 'direct catalog request grounded in the catalog (truthful, non-delivering)' do
    let(:catalog_plan) do
      plan(action: :send_catalog, operation: :start, reply: renderer.catalog(code: 'BD', name: 'Baby Doll'))
    end
    let(:document) { instance_double(Marine::Document, id: 30) }

    before { allow(orchestrator).to receive(:process).and_return(catalog_plan) }

    it 'previews a TRUTHFUL "would be shared" line plus a read-only metadata card when a catalog exists' do
      allow(selector).to receive(:call).and_return(document)
      allow(Marine::Documents::Serializer).to receive(:file_metadata).with(document).and_return(
        'filename' => 'baby-doll.pdf', 'content_type' => 'application/pdf', 'byte_size' => 2048
      )

      payload = preview.call(query: 'ada katalog baby doll ?', history: [])

      expect(payload['response']).to eq(
        'The Baby Doll catalog is available and would be shared with the customer in a full conversation.'
      )
      expect(payload['catalog_preview']).to eq(
        'family_name' => 'Baby Doll', 'filename' => 'baby-doll.pdf',
        'content_type' => 'application/pdf', 'byte_size' => 2048
      )
      expect(payload).to include('action' => 'reply', 'source_type' => 'marine_product', 'agent_name' => 'Marine Bot')
    end

    it 'marks catalog_sent in the next signed snapshot (one-catalog-per-flow) without delivering' do
      allow(selector).to receive(:call).and_return(document)
      allow(Marine::Documents::Serializer).to receive(:file_metadata).and_return(
        'filename' => 'c.pdf', 'content_type' => 'application/pdf', 'byte_size' => 10
      )

      preview.call(query: 'ada katalog baby doll ?', history: [])

      expect(token_signer).to have_received(:encode).with(hash_including('catalog_sent' => true, 'catalog_document_id' => 30))
    end

    it 'previews the honest no-catalog line (no card) when none exists' do
      allow(selector).to receive(:call).and_return(nil)

      payload = preview.call(query: 'ada katalog baby doll ?', history: [])

      expect(payload['response']).to eq("I'm sorry, I don't have a catalog available for Baby Doll right now.")
      expect(payload).not_to have_key('catalog_preview')
    end

    it 'previews the TRUTHFUL preview-already-shown line (never claims a file was shared) on a repeat' do
      # A continuation of the SAME family (operation :update) preserves the catalog_sent marker. The
      # preview never delivered a file, so the repeat must NOT say "I've already shared the catalog"
      # (the real-delivery wording) — only that the preview is already shown above.
      allow(orchestrator).to receive(:process).and_return(
        plan(action: :send_catalog, operation: :update, reply: renderer.catalog(code: 'BD', name: 'Baby Doll'))
      )
      allow(token_signer).to receive(:decode).and_return(
        'version' => 1, 'flow_id' => 'f', 'status' => 'active',
        'expires_at' => 1.hour.from_now.iso8601, 'validated_family' => 'BD', 'catalog_sent' => true
      )
      allow(selector).to receive(:call).and_return(document)

      payload = preview.call(query: 'ada katalog baby doll ?', history: [], state_token: 'prior')

      expect(payload['response']).to eq(
        'The Baby Doll catalog preview is already shown above; the file would be shared in a full conversation.'
      )
      expect(payload['response']).not_to include('already shared')
      expect(payload).not_to have_key('catalog_preview')
    end
  end

  describe 'other product actions' do
    it 'renders a parent_info reply payload' do
      allow(orchestrator).to receive(:process)
        .and_return(plan(action: :reply, reply: renderer.parent_info(code: 'BD', name: 'Baby Doll')))

      payload = preview.call(query: 'baby doll', history: [])

      expect(payload['response']).to eq("You're asking about Baby Doll. Which specific variant would you like to know about?")
      expect(payload['source_type']).to eq('marine_product')
    end

    it 'renders a product handoff as the factless acknowledgement, localized without a protected descriptor' do
      allow(orchestrator).to receive(:process)
        .and_return(plan(action: :handoff, reply: renderer.unsupported, handoff_category: 'exact_quantity'))

      payload = preview.call(query: 'berapa stok baby doll', history: [])

      expect(payload['response']).to eq(
        "I'm sorry, I can't confirm the exact quantity available for you directly. Let me bring in a colleague to help with this."
      )
      expect(Marine::Catalog::ReplyLocalizer).to have_received(:new).with(hash_including(action: nil, descriptor: nil))
    end
  end

  describe 'known catalog outage fails CLOSED (never RAG / never a fabricated answer)' do
    it 'returns the safe handoff acknowledgement when the orchestrator reports a catalog outage' do
      allow(orchestrator).to receive(:process).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)

      payload = preview.call(query: 'ada katalog baby doll', history: [])

      expect(payload).not_to be_nil
      expect(payload['response']).to eq(Marine::Catalog::ReplyPresenter::HANDOFF_ACK_TEXT)
      expect(payload['source_type']).to eq('marine_product')
    end

    it 'fails closed when the read-only catalog repository selection raises (real repository failure)' do
      allow(orchestrator).to receive(:process)
        .and_return(plan(action: :send_catalog, operation: :start, reply: renderer.catalog(code: 'BD', name: 'Baby Doll')))
      allow(selector).to receive(:call).and_raise(ActiveRecord::StatementInvalid.new('PG down'))

      payload = preview.call(query: 'ada katalog baby doll', history: [])

      expect(payload['response']).to eq(Marine::Catalog::ReplyPresenter::HANDOFF_ACK_TEXT)
    end
  end

  describe 'fail-safe: unexpected non-catalog errors fall through to RAG (nil) and are captured' do
    it 'falls through to RAG (nil) on an unexpected error and captures it' do
      allow(orchestrator).to receive(:process).and_raise(StandardError.new('boom'))
      tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
      allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)

      expect(preview.call(query: 'ada katalog baby doll', history: [])).to be_nil
      expect(tracker).to have_received(:capture_exception)
    end
  end

  describe 'isolation: no persisted state, no delivery, no side effects' do
    before do
      allow(orchestrator).to receive(:process)
        .and_return(plan(action: :reply, reply: renderer.parent_info(code: 'BD', name: 'Baby Doll')))
    end

    it 'never persists product-flow state and never delivers a message' do
      expect_any_instance_of(Marine::Catalog::ProductFlowStateStore).not_to receive(:start!)
      expect_any_instance_of(Marine::Catalog::ProductFlowStateStore).not_to receive(:update!)
      expect_any_instance_of(Marine::Catalog::ProductFlowStateStore).not_to receive(:reset!)
      expect_any_instance_of(Marine::Catalog::ProductFlowStateStore).not_to receive(:expire!)
      expect(Marine::Conversation::ProductMessageDeliveryService).not_to receive(:new)

      preview.call(query: 'baby doll', history: [])
    end

    it 'builds the in-memory state store with no conversation' do
      expect(Marine::Catalog::ProductFlowStateStore).to receive(:new).with(conversation: nil).and_call_original

      preview.call(query: 'baby doll', history: [])
    end
  end

  describe 'multi-turn history and state token' do
    it 'forwards the bounded/allowlisted history to the orchestrator and a fresh flow when no prior token' do
      history = [{ role: 'user', content: 'earlier' }, { role: 'assistant', content: 'reply' },
                 { role: 'system', content: 'dropped' }, { role: 'user', content: '  ' }]
      allow(orchestrator).to receive(:process).and_return(plan(action: :not_product))

      preview.call(query: 'follow up', history: history)

      expect(orchestrator).to have_received(:process).with(
        text: 'follow up',
        context: [{ role: 'user', content: 'earlier' }, { role: 'assistant', content: 'reply' }],
        flow: {}, suppressed: false, knowledge_available: false
      )
    end

    it 'plans over the decoded prior snapshot and returns a next signed token' do
      prior = { 'version' => 1, 'flow_id' => 'f', 'status' => 'active',
                'expires_at' => 1.hour.from_now.iso8601, 'validated_family' => 'BD' }
      allow(token_signer).to receive(:decode).and_return(prior)
      allow(orchestrator).to receive(:process)
        .and_return(plan(action: :reply, operation: :update, reply: renderer.parent_info(code: 'BD', name: 'Baby Doll')))

      payload = preview.call(query: 'baby doll', history: [], state_token: 'prior-token')

      expect(orchestrator).to have_received(:process).with(hash_including(flow: hash_including('validated_family' => 'BD')))
      expect(payload['state_token']).to eq('signed-token')
    end
  end
end
