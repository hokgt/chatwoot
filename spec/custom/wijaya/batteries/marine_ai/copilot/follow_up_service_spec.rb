# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Copilot::FollowUpService do
  let(:account) { instance_double(Account) }
  let(:base_service) { instance_double(Marine::Llm::BaseService) }
  let(:context) { { 'event_name' => 'improve', 'last_response' => 'Previous reply' } }

  before do
    allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
  end

  it 'requires a follow-up context' do
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, follow_up_context: {}, user_message: 'shorter').perform

    expect(result).to eq(message: nil, error: 'missing_follow_up_context')
  end

  it 'requires a non-blank message' do
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, follow_up_context: context, user_message: '  ').perform

    expect(result).to eq(message: nil, error: 'blank_message')
  end

  it 'degrades safely when the Marine LLM is not configured' do
    allow(base_service).to receive(:configured?).and_return(false)
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, follow_up_context: context, user_message: 'make it shorter').perform

    expect(result).to eq(message: nil, error: 'Marine LLM is not configured')
  end

  it 'refines the previous response and returns an updated context' do
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: true, message: 'Shorter reply', error: nil)

    result = described_class.new(account: account, follow_up_context: context, user_message: 'make it shorter').perform

    expect(result[:message]).to eq('Shorter reply')
    expect(result[:error]).to be_nil
    expect(result[:follow_up_context]).to include('event_name' => 'improve', 'last_response' => 'Shorter reply')
  end
end
