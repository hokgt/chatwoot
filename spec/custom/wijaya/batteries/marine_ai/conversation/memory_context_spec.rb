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
    start_message = create(:message, conversation: source, account: account, inbox: inbox, sender: contact,
                                     message_type: :incoming, private: false, content: 'source customer turn')
    end_message = create(:message, conversation: source, account: account, inbox: inbox, sender: assistant,
                                   message_type: :outgoing, private: false, content: 'source assistant reply')
    marker = Marine::Memory::Marker.build_v2(
      trigger_source: 'idle_timeout', conversation: source,
      start_id: start_message.id, end_id: end_message.id,
      fingerprint: Digest::SHA256.hexdigest("source-#{start_message.id}-#{end_message.id}")
    )
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

  it 'passes v2 advisory memory through the Agent personalization boundary without changing canonical product history' do
    trusted_memory('Customer previously mentioned SYN-OLD, which is advisory only.')
    prior = incoming('RECENT PUBLIC CONTEXT', at: 1.hour.ago)
    trigger = incoming('CURRENT PRODUCT REQUEST', at: Time.current)
    context = Marine::Conversation::ContextBuilder.new(conversation: conversation, trigger_message: trigger).build
    generator = instance_double(Marine::Charge::ResponseGenerator)
    runner = Marine::Agent::Runner.new(assistant: assistant, conversation: conversation, source: trigger)
    allow(runner).to receive(:response_generator).and_return(generator)
    expect(generator).to receive(:generate) do |additional_message:, message_history:, **|
      expect(additional_message).to eq('CURRENT PRODUCT REQUEST')
      expect(message_history.first.fetch(:content)).to include('ADVISORY HISTORICAL MEMORY', 'SYN-OLD')
      expect(message_history.last).to eq(role: 'user', content: prior.content)
      { 'response' => 'personalized' }
    end

    result = runner.send(:generated_response, context, context.history, context.trigger, nil)

    expect(result).to include('response' => 'personalized')
    expect(context.history).to eq([{ role: 'user', content: prior.content }])
    expect(context.trigger).to eq('CURRENT PRODUCT REQUEST')
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
