# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Memory::ContactNotesService do
  let(:account) { instance_double(Account, locale_english_name: 'English') }
  let(:notes) { double('notes') }
  let(:contact) { double('contact', notes: notes, to_llm_text: 'Contact summary') }
  let(:conversation) { double('conversation', contact: contact, account: account) }
  let(:assistant) { double('assistant') }
  let(:base_service) { instance_double(Marine::Llm::BaseService) }
  let(:context_builder) { instance_double(Marine::Copilot::ConversationContextBuilder, transcript: 'Customer: hi') }

  before do
    allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
    allow(Marine::Copilot::ConversationContextBuilder).to receive(:new).and_return(context_builder)
  end

  it 'no-ops when records are missing' do
    expect(base_service).not_to receive(:complete)

    result = described_class.new(assistant: assistant, conversation: nil).generate_and_store

    expect(result).to eq(ok: false, created: 0, error: 'missing_records')
  end

  it 'no-ops when the Marine LLM is not configured' do
    allow(base_service).to receive(:configured?).and_return(false)
    expect(base_service).not_to receive(:complete)

    result = described_class.new(assistant: assistant, conversation: conversation).generate_and_store

    expect(result).to eq(ok: false, created: 0, error: 'marine_llm_not_configured')
  end

  it 'creates one contact note when the LLM returns text' do
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: true, message: '{"notes": ["Prefers email contact"]}', error: nil)
    allow(notes).to receive(:exists?).with(content: 'Prefers email contact').and_return(false)
    expect(notes).to receive(:create!).with(content: 'Prefers email contact')

    result = described_class.new(assistant: assistant, conversation: conversation).generate_and_store

    expect(result).to eq(ok: true, created: 1, error: nil)
  end

  it 'dedupes notes that already exist for the contact' do
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: true, message: '{"notes": ["Prefers email contact"]}', error: nil)
    allow(notes).to receive(:exists?).with(content: 'Prefers email contact').and_return(true)
    expect(notes).not_to receive(:create!)

    result = described_class.new(assistant: assistant, conversation: conversation).generate_and_store

    expect(result).to eq(ok: true, created: 0, error: nil)
  end

  it 'no-ops without raising when the LLM call fails' do
    allow(base_service).to receive(:configured?).and_return(true)
    allow(base_service).to receive(:complete).and_return(ok: false, message: nil, error: 'boom')
    expect(notes).not_to receive(:create!)

    result = described_class.new(assistant: assistant, conversation: conversation).generate_and_store

    expect(result).to eq(ok: true, created: 0, error: nil)
  end
end
