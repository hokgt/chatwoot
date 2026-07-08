# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::BaseService do
  subject(:service) { described_class.new(account: account) }

  let(:account) { create(:account) }

  describe '#chat when not configured' do
    before { allow(Marine::Llm::Config).to receive(:configured?).and_return(false) }

    it 'returns a normalized not-configured result without calling the provider' do
      expect(RubyLLM).not_to receive(:context)

      result = service.chat(messages: [{ role: 'user', content: 'hi' }])

      expect(result).to include(ok: false, message: nil, error: 'Marine LLM is not configured', raw: nil)
      expect(result[:model]).to eq('gpt-4.1-mini')
    end
  end

  describe '#chat when configured' do
    let(:response) { instance_double(RubyLLM::Message, content: 'hello there') }
    let(:chat) { instance_double(RubyLLM::Chat) }

    before do
      allow(Marine::Llm::Config).to receive(:configured?).and_return(true)
      allow(service).to receive(:build_chat).and_return(chat)
      allow(chat).to receive(:with_instructions)
      allow(chat).to receive(:add_message)
      allow(chat).to receive(:ask).and_return(response)
    end

    it 'returns a normalized success result' do
      result = service.chat(messages: [{ role: 'user', content: 'hi' }], system: 'be nice')

      expect(result).to include(ok: true, message: 'hello there', error: nil, raw: response)
      expect(chat).to have_received(:with_instructions).with('be nice')
    end

    it 'returns a no-messages result when only a system message is present' do
      result = service.chat(messages: [{ role: 'system', content: 'be nice' }])

      expect(result).to include(ok: false, error: 'No conversation messages provided')
    end

    it 'captures exceptions and returns a normalized error result' do
      allow(chat).to receive(:ask).and_raise(StandardError, 'upstream boom')
      expect_any_instance_of(ChatwootExceptionTracker).to receive(:capture_exception)

      result = service.chat(messages: [{ role: 'user', content: 'hi' }])

      expect(result).to include(ok: false, message: nil, error: 'upstream boom', raw: nil)
    end

    it 'does not leak the API key in the result' do
      allow(Marine::Llm::Config).to receive(:api_key).and_return('sk-secret')

      result = service.chat(messages: [{ role: 'user', content: 'hi' }])

      expect(result.to_s).not_to include('sk-secret')
    end
  end
end
