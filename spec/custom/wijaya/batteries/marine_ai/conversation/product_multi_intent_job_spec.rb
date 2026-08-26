# frozen_string_literal: true

require 'rails_helper'

# D6 — full trigger-bound job-path structural proof: one inbound message that carried a supported
# price+stock pair produces exactly ONE outgoing action/message carrying BOTH facts, applies flow
# state once, completes the claim, and a duplicate delivery of the same incoming message remains
# idempotent (no second output, no double usage). The composite descriptor is delivered through the
# unchanged generic product path (no channel conditional, no second delivery).
RSpec.describe Marine::Conversation::ResponseBuilderJob do
  describe '#perform (multi-intent composite)' do
    let(:conversation) { create(:conversation) }
    let(:assistant) { create(:marine_assistant, account: conversation.account) }
    let(:incoming) { create(:message, conversation: conversation, message_type: :incoming, content: 'price and stock for impeller 3 inch') }

    let(:composite_reply) do
      { kind: :composite,
        parts: [
          { kind: :price_available, variant_code: 'IMP-3', price_list_rate: '150000', currency: 'IDR', uom: 'pcs' },
          { kind: :stock_available }
        ] }
    end

    def stub_reasoning(payload)
      chat = instance_double(Marine::Llm::AssistantChatService, generate_response: payload)
      allow(Marine::Llm::AssistantChatService).to receive(:new).and_return(chat)
    end

    def composite_payload
      {
        'action' => 'product', 'orchestration_path' => 'product',
        'product_plan' => {
          action: :reply, reply: composite_reply,
          state: { operation: :update,
                   changes: { 'validated_family' => 'IMP', 'validated_variant' => 'IMP-3',
                              'current_intent' => 'price', 'requested_intents' => nil } }
        }
      }
    end

    def claim_status
      incoming.reload.additional_attributes.dig('wijaya_marine_ai', 'processing_claim_v1', 'status')
    end

    def usage_count
      conversation.account.reload.custom_attributes['marine_responses_usage'].to_i
    end

    it 'delivers ONE message carrying both the price and the availability fact, once' do
      stub_reasoning(composite_payload)

      described_class.perform_now(conversation, assistant, incoming.id)

      conversation.messages.reload
      replies = conversation.messages.outgoing
      expect(replies.count).to eq(1)
      content = replies.last.content
      expect(content).to include('IDR 150000')
      expect(content).to include('IMP-3')
      expect(content).to include('in stock')
      expect(replies.last.attachments).to be_empty
      expect(replies.last.additional_attributes['source_type']).to eq('marine_product')
      expect(usage_count).to eq(1)
      expect(claim_status).to eq('completed')
    end

    it 'delivers the exact deterministic composite text with a quantity-free availability fact' do
      stub_reasoning(composite_payload)

      described_class.perform_now(conversation, assistant, incoming.id)

      content = conversation.messages.outgoing.last.content
      # Deterministic English (no LLM configured in test): price fact + binary availability, one line.
      expect(content).to eq('The price for IMP-3 is IDR 150000 per pcs. Good news — that item is currently in stock.')
    end

    it 'remains idempotent on a duplicate delivery of the same incoming message' do
      stub_reasoning(composite_payload)

      described_class.perform_now(conversation, assistant, incoming.id)
      described_class.perform_now(conversation, assistant, incoming.id)

      expect(conversation.messages.outgoing.count).to eq(1)
      expect(usage_count).to eq(1)
    end
  end
end
