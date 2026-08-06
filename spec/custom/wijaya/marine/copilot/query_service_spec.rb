# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Copilot::QueryService do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:marine_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }

  describe '#answer when the Marine LLM is unconfigured' do
    before { allow(Marine::Llm::Config).to receive(:configured?).and_return(false) }

    it 'degrades to returning matching record citations without raising' do
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:message, account: account, inbox: inbox, conversation: conversation, content: 'I need a refund please')

      result = described_class.new(assistant: assistant, user: admin).answer(question: 'refund')

      expect(result[:error]).to be_nil
      expect(result[:content]).to include('not configured')
      expect(result[:citations].map { |c| c[:id] }).to include(conversation.display_id)
    end

    it 'returns a clear no-results message when nothing matches' do
      result = described_class.new(assistant: assistant, user: admin).answer(question: 'nonexistentquery')

      expect(result[:error]).to be_nil
      expect(result[:content]).to include('No matching')
      expect(result[:citations]).to eq([])
    end
  end

  describe '#answer when the Marine LLM is configured' do
    before { allow(Marine::Llm::Config).to receive(:configured?).and_return(true) }

    it 'synthesizes an answer and attaches citations' do
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:message, account: account, inbox: inbox, conversation: conversation, content: 'refund requested')
      allow_any_instance_of(Marine::Llm::BaseService).to receive(:chat).and_return(
        { ok: true, message: 'One conversation mentions a refund.', error: nil }
      )

      result = described_class.new(assistant: assistant, user: admin).answer(question: 'refund')

      expect(result[:content]).to eq('One conversation mentions a refund.')
      expect(result[:citations].map { |c| c[:id] }).to include(conversation.display_id)
      expect(result[:error]).to be_nil
    end

    it 'falls back to citations when the LLM call fails' do
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:message, account: account, inbox: inbox, conversation: conversation, content: 'refund requested')
      allow_any_instance_of(Marine::Llm::BaseService).to receive(:chat).and_return(
        { ok: false, message: nil, error: 'boom' }
      )

      result = described_class.new(assistant: assistant, user: admin).answer(question: 'refund')

      expect(result[:error]).to be_nil
      expect(result[:citations].map { |c| c[:id] }).to include(conversation.display_id)
    end
  end

  describe '#answer with a blank question' do
    it 'returns a validation error' do
      result = described_class.new(assistant: assistant, user: admin).answer(question: '  ')

      expect(result[:error]).to eq('Question is required')
    end
  end
end
