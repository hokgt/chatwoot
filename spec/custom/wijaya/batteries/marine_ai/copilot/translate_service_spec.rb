# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Copilot::TranslateService do
  let(:account) { instance_double(Account) }
  let(:translate_response_service) { instance_double(Marine::Llm::TranslateResponseService) }

  it 'rejects blank content without invoking translation' do
    expect(Marine::Llm::TranslateResponseService).not_to receive(:new)

    result = described_class.new(account: account, content: '  ', target_language: 'id').perform

    expect(result).to eq(message: nil, error: 'blank_content')
  end

  it 'rejects a blank target language' do
    expect(Marine::Llm::TranslateResponseService).not_to receive(:new)

    result = described_class.new(account: account, content: 'Hello', target_language: ' ').perform

    expect(result).to eq(message: nil, error: 'missing_target_language')
  end

  it 'delegates to the Marine multilingual translate service and returns translated text' do
    allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(translate_response_service)
    allow(translate_response_service).to receive(:call).and_return(
      ok: true, text: 'Halo dunia', source_language: 'en', target_language: 'id', translated: true, error: nil
    )

    result = described_class.new(account: account, content: 'Hello world', target_language: 'id').perform

    expect(result[:message]).to eq('Halo dunia')
    expect(result[:error]).to be_nil
    expect(result[:follow_up_context]).to include(event_name: 'translate', target_language: 'id', source_language: 'en')
  end

  it 'surfaces a translation failure as an error result' do
    allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(translate_response_service)
    allow(translate_response_service).to receive(:call).and_return(
      ok: false, text: 'Hello world', source_language: 'en', target_language: 'id', translated: false, error: 'upstream boom'
    )

    result = described_class.new(account: account, content: 'Hello world', target_language: 'id').perform

    expect(result).to eq(message: nil, error: 'upstream boom')
  end
end
