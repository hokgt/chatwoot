# frozen_string_literal: true

require 'rails_helper'

# The dynamic refusal generator. It receives ONLY a normalized deny category and an allowlisted
# language code — never the raw request, history, or internal control text — and returns a bare
# { "reply": <string> } envelope body, or nil on any failure.
RSpec.describe Marine::Circuit::BoundaryReplyComposer do
  let(:composer) { described_class.new }

  def stub_llm(message:, success: true, configured: true)
    llm = instance_double(Marine::Llm::BaseService, configured?: configured)
    allow(llm).to receive(:chat).and_return({ ok: success, message: message, error: nil })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    llm
  end

  def envelope(reply)
    { reply: reply }.to_json
  end

  it 'returns the generated refusal for a describable category' do
    stub_llm(message: envelope('Sorry, I can only help with Textilindo. What can I help you find?'))
    expect(composer.compose(category: :unrelated)).to include('Textilindo')
  end

  it 'returns nil for an unknown/non-describable category (e.g. the :error sentinel)' do
    stub_llm(message: envelope('x'))
    expect(composer.compose(category: :error)).to be_nil
  end

  it 'passes the normalized category description and language directive as system, with no raw text' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured.merge!(args)
      { ok: true, message: envelope('ok'), error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)

    composer.compose(category: :extraction, language: 'id')

    expect(captured[:system]).to include(described_class::GENERATION_INSTRUCTION)
    expect(captured[:system]).to include(Marine::Circuit::DomainSecurityDecisionService::CATEGORY_DESCRIPTIONS['extraction'])
    expect(captured[:system]).to include('language code: id')
    expect(captured[:temperature]).to eq(0.0)
    expect(captured[:schema][:strict]).to be(true)
  end

  it 'omits the language directive when no language is provided' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured.merge!(args)
      { ok: true, message: envelope('ok'), error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)

    composer.compose(category: :unrelated)

    expect(captured[:system]).not_to include('language code')
  end

  describe 'fail-closed extraction' do
    it 'returns nil when unconfigured' do
      allow(Marine::Llm::BaseService).to receive(:new).and_return(instance_double(Marine::Llm::BaseService, configured?: false))
      expect(composer.compose(category: :unrelated)).to be_nil
    end

    it 'returns nil on an LLM error' do
      stub_llm(message: nil, success: false)
      expect(composer.compose(category: :unrelated)).to be_nil
    end

    it 'returns nil when the call raises' do
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat).and_raise(StandardError)
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      expect(composer.compose(category: :unrelated)).to be_nil
    end

    it 'returns nil on a fenced/prose envelope (no repair)' do
      stub_llm(message: "```json\n#{envelope('hi')}\n```")
      expect(composer.compose(category: :unrelated)).to be_nil
    end

    it 'returns nil on a wrong-shape envelope' do
      stub_llm(message: '{"text":"hi"}')
      expect(composer.compose(category: :unrelated)).to be_nil
    end

    it 'returns nil on a duplicated key' do
      stub_llm(message: '{"reply":"a","reply":"b"}')
      expect(composer.compose(category: :unrelated)).to be_nil
    end
  end
end
