# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::PlaygroundPreview do
  let(:account) { instance_double(Account) }
  let(:assistant) { double('assistant', name: 'Marine Bot', config: { 'language' => 'id' }) }
  let(:orchestrator) { instance_double(Marine::Catalog::ProductQueryOrchestrator) }
  let(:localizer) { instance_double(Marine::Catalog::ReplyLocalizer) }
  let(:selector) { instance_double(Marine::Documents::ProductCatalogSelector) }
  let(:renderer) { Marine::Catalog::ReplyRenderer.new }

  subject(:preview) { described_class.new(assistant: assistant, account: account) }

  def plan(action:, reply: nil, changes: {}, language: 'id', handoff_category: nil)
    { action: action, reply: reply, state: { operation: :none, changes: changes },
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

  describe 'catalog request grounded in the catalog (no false "unavailable")' do
    let(:catalog_plan) { plan(action: :send_catalog, reply: renderer.catalog(code: 'BD', name: 'Baby Doll')) }

    before { allow(orchestrator).to receive(:process).and_return(catalog_plan) }

    it 'previews the caption when a usable primary catalog exists, without delivering it' do
      allow(selector).to receive(:call).and_return(instance_double(Marine::Document))

      payload = preview.call(query: 'ada katalog baby doll ?', history: [])

      expect(payload).to include(
        'response' => 'Here is the product catalog for Baby Doll.',
        'action' => 'reply',
        'agent_name' => 'Marine Bot',
        'source_type' => 'marine_product',
        'orchestration_path' => 'product'
      )
      expect(selector).to have_received(:call)
      expect(Marine::Catalog::ReplyLocalizer).to have_received(:new)
        .with(hash_including(text: 'Here is the product catalog for Baby Doll.', action: :send_catalog))
    end

    it 'previews the honest no-catalog line when none exists' do
      allow(selector).to receive(:call).and_return(nil)

      payload = preview.call(query: 'ada katalog baby doll ?', history: [])

      expect(payload['response']).to eq("I'm sorry, I don't have a catalog available for Baby Doll right now.")
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

    it 'renders a clarify_family reply payload' do
      allow(orchestrator).to receive(:process)
        .and_return(plan(action: :clarify_family, reply: renderer.clarify_family([{ code: 'BD', name: 'Baby Doll' }])))

      payload = preview.call(query: 'kain baby doll', history: [])

      expect(payload['response']).to eq('Could you let me know which product you mean? For example: Baby Doll.')
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

  describe 'fail-safe: never raises, no side effects' do
    it 'falls through to RAG (nil) when the catalog is unavailable' do
      allow(orchestrator).to receive(:process).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)
      expect(preview.call(query: 'ada katalog baby doll', history: [])).to be_nil
    end

    it 'falls through to RAG (nil) on an unexpected error and captures it' do
      allow(orchestrator).to receive(:process).and_raise(StandardError.new('boom'))
      tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
      allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)

      expect(preview.call(query: 'ada katalog baby doll', history: [])).to be_nil
      expect(tracker).to have_received(:capture_exception)
    end

    it 'never touches the persisted product flow store or the message delivery service' do
      allow(orchestrator).to receive(:process).and_return(plan(action: :reply, reply: renderer.parent_info(code: 'BD', name: 'Baby Doll')))
      expect(Marine::Catalog::ProductFlowStateStore).not_to receive(:new)
      expect(Marine::Conversation::ProductMessageDeliveryService).not_to receive(:new)

      preview.call(query: 'baby doll', history: [])
    end
  end

  describe 'multi-turn history feeds intent extraction' do
    it 'forwards the bounded history to the orchestrator as context with an empty flow snapshot' do
      history = [{ role: 'user', content: 'earlier' }, { role: 'assistant', content: 'reply' }]
      allow(orchestrator).to receive(:process).and_return(plan(action: :not_product))

      preview.call(query: 'follow up', history: history)

      expect(orchestrator).to have_received(:process)
        .with(text: 'follow up', context: history, flow: {}, suppressed: false)
    end
  end
end
