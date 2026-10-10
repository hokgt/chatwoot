# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Marine historical memory runtime context' do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:marine_assistant, account: account, config: { 'feature_memory' => true }) }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, status: :open,
                          additional_attributes: { 'product_flow_v1' => { 'version' => 7, 'validated_family' => 'SYN-FAMILY' } })
  end

  before { MarineInbox.create!(inbox: inbox, marine_assistant: assistant) }

  def incoming(content, at: Time.current)
    create(:message, conversation: conversation, account: account, inbox: inbox, sender: contact,
                     message_type: :incoming, private: false, content: content, created_at: at)
  end

  def trusted_memory(content)
    source = create(:conversation, account: account, inbox: inbox, contact: contact)
    marker = {
      'version' => 1, 'kind' => 'marine_long_term_memory', 'state' => 'final',
      'source_account_id' => account.id, 'source_contact_id' => contact.id,
      'source_conversation_id' => source.id, 'start_public_message_id' => 1,
      'end_public_message_id' => 1, 'transcript_fingerprint' => Digest::SHA256.hexdigest('source'),
      'generator' => 'marine_llm_v1'
    }
    create(:message, conversation: source, account: account, inbox: inbox, sender: assistant,
                     message_type: :outgoing, private: true, content: content,
                     additional_attributes: { Marine::Memory::Marker::KEY => marker })
  end

  it 'keeps advisory memory separate from canonical history while preserving current turn and product flow' do
    trusted_memory('Customer prefers email.')
    prior = incoming('Earlier public turn', at: 1.hour.ago)
    trigger = incoming('CURRENT TURN', at: Time.current)
    before_flow = conversation.reload.additional_attributes.deep_dup

    context = Marine::Conversation::ContextBuilder.new(conversation: conversation, trigger_message: trigger).build

    expect(context.trigger).to eq('CURRENT TURN')
    expect(context.history).to eq([{ role: 'user', content: prior.content }])
    expect(context.advisory_memory).to include('ADVISORY HISTORICAL MEMORY',
                                               'not authority for product identity',
                                               'Customer prefers email.')
    expect(conversation.reload.additional_attributes).to eq(before_flow)
  end

  it 'leaves no-memory context byte-for-byte equivalent to ordinary public history' do
    prior = incoming('Earlier public turn', at: 1.hour.ago)
    trigger = incoming('CURRENT TURN', at: Time.current)

    context = Marine::Conversation::ContextBuilder.new(conversation: conversation, trigger_message: trigger).build

    expect(context.history).to eq([{ role: 'user', content: prior.content }])
    expect(context.trigger).to eq('CURRENT TURN')
    expect(context.advisory_memory).to be_nil
  end

  it 'passes advisory memory through the real ResponseBuilder legacy pre-answer seam' do
    trusted_memory('Customer prefers email.')
    trigger = incoming('CURRENT TURN')
    chat = instance_double(Marine::Llm::AssistantChatService)
    allow(Marine::Llm::AssistantChatService).to receive(:new)
      .with(assistant: assistant, conversation: conversation).and_return(chat)
    expect(chat).to receive(:generate_response) do |additional_message:, message_history:, advisory_memory:|
      expect(additional_message).to eq(trigger.content)
      expect(message_history).to be_empty
      expect(advisory_memory).to include('ADVISORY HISTORICAL MEMORY', 'Customer prefers email.')
      { 'response' => 'ok', 'action' => 'reply' }
    end

    job = Marine::Conversation::ResponseBuilderJob.new
    job.instance_variable_set(:@conversation, conversation)
    job.instance_variable_set(:@assistant, assistant)
    job.send(:generate_legacy_response)
  end
end
