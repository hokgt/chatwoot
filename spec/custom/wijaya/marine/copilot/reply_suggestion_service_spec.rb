# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Copilot::ReplySuggestionService do
  let(:account) { instance_double(Account) }
  let(:user) { double('user', name: 'Agent Smith') }
  let(:conversation) { double('conversation', inbox: nil) }
  let(:base_service) { instance_double(Marine::Llm::BaseService) }
  let(:context_builder) { instance_double(Marine::Copilot::ConversationContextBuilder) }

  before do
    allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
    allow(Marine::Copilot::ConversationContextBuilder).to receive(:new).and_return(context_builder)
  end

  it 'returns a validation error when there is no conversation' do
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, conversation: nil, user: user).perform

    expect(result).to eq(message: nil, error: 'conversation_not_found')
  end

  it 'returns a validation error when the transcript is empty' do
    allow(context_builder).to receive(:transcript).and_return('')
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, conversation: conversation, user: user).perform

    expect(result).to eq(message: nil, error: 'empty_conversation')
  end

  it 'degrades safely when the Marine LLM is not configured' do
    allow(context_builder).to receive(:transcript).and_return('Customer: hi')
    allow(base_service).to receive(:configured?).and_return(false)
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, conversation: conversation, user: user).perform

    expect(result).to eq(message: nil, error: 'Marine LLM is not configured')
  end

  it 'drafts a reply suggestion from the conversation transcript' do
    allow(context_builder).to receive(:transcript).and_return('Customer: where is my order?')
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: true, message: 'Your order ships today.', error: nil)

    result = described_class.new(account: account, conversation: conversation, user: user).perform

    expect(result[:message]).to eq('Your order ships today.')
    expect(result[:error]).to be_nil
    expect(result[:follow_up_context]).to include(event_name: 'reply_suggestion')
  end
end
