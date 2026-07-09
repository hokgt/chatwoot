# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Copilot::RewriteService do
  let(:account) { instance_double(Account) }
  let(:base_service) { instance_double(Marine::Llm::BaseService) }

  before do
    allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
  end

  it 'rejects an unknown operation without calling the LLM' do
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, content: 'hi', operation: 'nonsense').perform

    expect(result).to eq(message: nil, error: 'invalid_operation')
  end

  it 'rejects blank content without calling the LLM' do
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, content: '   ', operation: 'improve').perform

    expect(result).to eq(message: nil, error: 'blank_content')
  end

  it 'degrades safely when the Marine LLM is not configured' do
    allow(base_service).to receive(:configured?).and_return(false)
    expect(base_service).not_to receive(:complete)

    result = described_class.new(account: account, content: 'fix me', operation: 'improve').perform

    expect(result).to eq(message: nil, error: 'Marine LLM is not configured')
  end

  it 'returns rewritten content with follow-up context on success' do
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: true, message: 'Improved text', error: nil)

    result = described_class.new(account: account, content: 'raw text', operation: 'improve').perform

    expect(result[:message]).to eq('Improved text')
    expect(result[:error]).to be_nil
    expect(result[:follow_up_context]).to include(event_name: 'improve', original_context: 'raw text', last_response: 'Improved text')
  end

  it 'surfaces provider errors as a failure result' do
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: false, message: nil, error: 'boom')

    result = described_class.new(account: account, content: 'raw text', operation: 'shorten').perform

    expect(result).to eq(message: nil, error: 'boom')
  end
end
