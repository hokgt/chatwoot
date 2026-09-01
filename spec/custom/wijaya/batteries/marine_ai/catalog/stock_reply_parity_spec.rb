# frozen_string_literal: true

require 'rails_helper'

# Conversation <-> source-less Playground PARITY for a pure stock reply.
#
# Reproduces the reported inconsistency: for the SAME account/assistant/context/catalog state and the
# SAME deterministic stock result, the trigger-bound conversation and the source-less Playground must
# reach the IDENTICAL business conclusion — DELIVER an in-language stock line, or HAND OFF. The bug
# was that the conversation ran a fail-closed customer-language gate (handing off when the localized
# stock line could not be proven in-language) while the Playground skipped it and asserted
# availability. Both now consume Marine::Catalog::StockReplyComposer, so their conclusions match.
#
# The wording service, localizer, and language detector are stubbed identically for both surfaces so
# the ONLY thing under test is that each surface turns the same descriptor into the same conclusion.
RSpec.describe 'Marine stock reply conversation<->playground parity' do
  let(:conversation) { create(:conversation) }
  let(:assistant) { create(:marine_assistant, account: conversation.account) }
  let(:incoming) { create(:message, conversation: conversation, message_type: :incoming, content: 'apakah BD-1 tersedia') }

  let(:renderer) { Marine::Catalog::ReplyRenderer.new }
  let(:stock_descriptor) { renderer.stock_available('BD-1') }
  let(:empty_descriptor) { renderer.stock_empty('BD-1') }
  let(:english_stock) { 'BD-1 is currently in stock.' }
  let(:english_empty) { "I'm sorry, BD-1 is currently out of stock." }
  let(:localized_stock) { 'BD-1 saat ini tersedia.' }
  let(:ack_en) { Marine::Catalog::ReplyPresenter::HANDOFF_ACK_TEXT }
  let(:ack_id) { 'Maaf, saya belum bisa memastikannya. Saya akan menghubungkan Anda dengan rekan.' }

  # --- Shared stubs applied identically to both surfaces -------------------------------------------

  def stub_wording(result)
    service = instance_double(Marine::Catalog::GroundedProductWordingService, call: result)
    allow(Marine::Catalog::GroundedProductWordingService).to receive(:new).and_return(service)
  end

  def stub_localizer(map)
    allow(Marine::Catalog::ReplyLocalizer).to receive(:new) do |**kwargs|
      instance_double(Marine::Catalog::ReplyLocalizer, call: map.fetch(kwargs[:text], kwargs[:text]))
    end
  end

  def stub_detector(map)
    allow(Marine::Llm::LanguageDetector).to receive(:new) do |text|
      reading = map.fetch(text, { language: 'unknown', reliable: false, confidence: 0.0 })
      instance_double(Marine::Llm::LanguageDetector, detect: reading)
    end
  end

  # --- Conversation adapter -----------------------------------------------------------------------

  def conversation_plan(descriptor, language: 'id')
    { 'action' => 'product', 'orchestration_path' => 'product',
      'product_plan' => { action: :reply, reply: descriptor, language: language,
                          state: { operation: :update, changes: { 'validated_family' => 'BD', 'current_intent' => 'stock' } } } }
  end

  def run_conversation(descriptor, language: 'id')
    chat = instance_double(Marine::Llm::AssistantChatService, generate_response: conversation_plan(descriptor, language: language))
    allow(Marine::Llm::AssistantChatService).to receive(:new).and_return(chat)
    Marine::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, incoming.id)
    conversation.reload
  end

  def conversation_visible
    conversation.messages.outgoing.where(private: false)
  end

  def conversation_handoff?
    Marine::Circuit::HandoffStateStore.new(conversation: conversation.reload).active?
  end

  # --- Playground adapter -------------------------------------------------------------------------

  def playground_plan(descriptor, language: 'id')
    { action: :reply, reply: descriptor, language: language, handoff_category: nil,
      state: { operation: :update, changes: { 'validated_family' => 'BD', 'current_intent' => 'stock' } } }
  end

  def run_playground(descriptor, language: 'id')
    orchestrator = instance_double(Marine::Catalog::ProductQueryOrchestrator, process: playground_plan(descriptor, language: language))
    allow(Marine::Catalog::ProductQueryOrchestrator).to receive(:new).and_return(orchestrator)
    token = instance_double(Marine::Catalog::PlaygroundStateToken, decode: nil, encode: 'tok')
    allow(Marine::Catalog::PlaygroundStateToken).to receive(:new).and_return(token)
    Marine::Catalog::PlaygroundPreview.new(assistant: assistant, account: conversation.account).call(query: 'apakah BD-1 tersedia')
  end

  # ================================================================================================

  describe 'available stock, Indonesian, localization succeeds -> BOTH DELIVER the same stock line' do
    before do
      stub_wording(nil) # candidate rejected: the deterministic in-language fallback is delivered
      stub_localizer(english_stock => localized_stock)
      stub_detector(localized_stock => { language: 'id', reliable: true, confidence: 0.99 })
    end

    it 'conversation delivers the in-language stock line, no handoff' do
      run_conversation(stock_descriptor)
      expect(conversation_visible.last.content).to eq(localized_stock)
      expect(conversation_handoff?).to be(false)
    end

    it 'playground delivers the SAME in-language stock line' do
      payload = run_playground(stock_descriptor)
      expect(payload['response']).to eq(localized_stock)
    end

    it 'reaches the identical DELIVER conclusion on both surfaces' do
      run_conversation(stock_descriptor)
      payload = run_playground(stock_descriptor)
      expect(conversation_visible.last.content).to eq(payload['response'])
      expect(payload['response']).to eq(localized_stock)
    end
  end

  describe 'available stock, Indonesian, localization degrades to English -> BOTH HAND OFF (the reported bug)' do
    before do
      stub_wording(nil)
      # The stock line degrades to the English source; the factless acknowledgement localizes to id.
      stub_localizer(english_stock => english_stock, ack_en => ack_id)
      stub_detector(english_stock => { language: 'en', reliable: true, confidence: 0.99 },
                    ack_id => { language: 'id', reliable: true, confidence: 0.99 })
    end

    it 'conversation refuses the English stock line and hands off (product_stock_available) with the in-language acknowledgement' do
      run_conversation(stock_descriptor)

      expect(conversation.messages.where(content: english_stock)).to be_empty
      expect(conversation_visible.last.content).to eq(ack_id)
      expect(conversation_handoff?).to be(true)
      expect(conversation.messages.where(private: true).map(&:content)).to include(a_string_including('product_stock_available'))
    end

    it 'playground ALSO refuses the English stock line and shows the same handoff acknowledgement (no availability claim)' do
      payload = run_playground(stock_descriptor)

      expect(payload['response']).to eq(ack_id)
      expect(payload['response']).not_to include('in stock')
    end

    it 'reaches the identical HAND OFF conclusion on both surfaces (neither asserts availability)' do
      run_conversation(stock_descriptor)
      payload = run_playground(stock_descriptor)

      expect(conversation_visible.last.content).to eq(payload['response'])
      expect(payload['response']).to eq(ack_id)
      expect(conversation_handoff?).to be(true)
    end
  end

  describe 'out-of-stock, Indonesian, localization degrades to English -> BOTH HAND OFF (no invented availability)' do
    before do
      stub_wording(nil)
      stub_localizer(english_empty => english_empty, ack_en => ack_id)
      stub_detector(english_empty => { language: 'en', reliable: true, confidence: 0.99 },
                    ack_id => { language: 'id', reliable: true, confidence: 0.99 })
    end

    it 'both surfaces hand off with the same acknowledgement rather than shipping an English out-of-stock line' do
      run_conversation(empty_descriptor)
      payload = run_playground(empty_descriptor)

      expect(conversation.messages.where(content: english_empty)).to be_empty
      expect(conversation_visible.last.content).to eq(ack_id)
      expect(conversation_handoff?).to be(true)
      expect(payload['response']).to eq(ack_id)
    end
  end

  describe 'English (source) target -> BOTH DELIVER the English stock line, no needless handoff' do
    before { stub_wording(nil) }

    it 'delivers the English stock line on both surfaces' do
      run_conversation(stock_descriptor, language: 'en')
      payload = run_playground(stock_descriptor, language: 'en')

      expect(conversation_visible.last.content).to eq(english_stock)
      expect(conversation_handoff?).to be(false)
      expect(payload['response']).to eq(english_stock)
    end
  end
end
