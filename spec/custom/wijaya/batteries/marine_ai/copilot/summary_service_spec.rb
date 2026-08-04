# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Copilot::SummaryService do
  let(:account) { instance_double(Account, locale_english_name: 'English') }
  let(:conversation) { double('conversation') }
  let(:base_service) { instance_double(Marine::Llm::BaseService) }
  let(:context_builder) { instance_double(Marine::Copilot::ConversationContextBuilder) }

  before do
    allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
    allow(Marine::Copilot::ConversationContextBuilder).to receive(:new).and_return(context_builder)
  end

  it 'requires a conversation' do
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, conversation: nil).perform

    expect(result).to eq(message: nil, error: 'conversation_not_found')
  end

  it 'requires a transcript' do
    allow(context_builder).to receive(:transcript).and_return('')
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, conversation: conversation).perform

    expect(result).to eq(message: nil, error: 'empty_conversation')
  end

  it 'degrades safely when the Marine LLM is not configured' do
    allow(context_builder).to receive(:transcript).and_return('Customer: hi')
    allow(base_service).to receive(:configured?).and_return(false)
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, conversation: conversation).perform

    expect(result).to eq(message: nil, error: 'Marine LLM is not configured')
  end

  it 'summarizes conversation context' do
    allow(context_builder).to receive(:transcript).and_return('Customer: issue\nAgent: reply')
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: true, message: 'Short summary', error: nil)

    result = described_class.new(account: account, conversation: conversation).perform

    expect(result[:message]).to eq('Short summary')
    expect(result[:error]).to be_nil
    expect(result[:follow_up_context]).to include(event_name: 'summarize')
  end
end
