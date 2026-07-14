# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Charge::ResponseGenerator do
  let(:assistant) { double('assistant', name: 'Marine Bot') }
  let(:knowledge_base) { instance_double(Marine::Cell::KnowledgeBaseService) }
  let(:generator) { described_class.new(assistant: assistant) }

  before do
    allow(Marine::Cell::KnowledgeBaseService).to receive(:new).with(assistant: assistant).and_return(knowledge_base)
  end

  # Keep translation a no-op by default so the commit 2 assertions stay stable.
  def stub_no_translation
    allow(Marine::Llm::TranslateQueryService).to receive(:new).and_return(
      double(call: { text: nil, source_language: 'en', translated: false, error: nil })
    )
    allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(
      double(call: { text: nil, source_language: 'en', target_language: 'en', translated: false, error: nil })
    )
  end

  it 'returns a reply payload with confidence and citation metadata when confident' do
    stub_no_translation
    response = Marine::AssistantResponse.new(id: 9, question: 'Hi', answer: 'Hello!')
    result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 0.9)
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'Hi')

    expect(payload).to include(
      'response' => 'Hello!',
      'action' => 'reply',
      'agent_name' => 'Marine Bot',
      'marine_cell_response_id' => 9,
      'confidence' => 0.9,
      'source_type' => 'manual',
      'response_ids' => [9],
      'document_ids' => [],
      'fallback_reason' => nil
    )
    expect(payload['citations']).to be_an(Array)
  end

  # Keep the LLM fallback out of the way by default so handoff assertions stay stable.
  def stub_llm_unconfigured
    allow(Marine::Llm::BaseService).to receive(:new).and_return(double(configured?: false))
  end

  it 'hands off using the low-confidence payload when there is no confident match' do
    stub_no_translation
    stub_llm_unconfigured
    result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'unknown')

    expect(payload).to include(
      'response' => 'conversation_handoff',
      'action' => 'handoff',
      'action_reason' => 'no_confident_cell_match'
    )
  end

  it 'uses LLM fallback for conversational response when retrieval fails and LLM is configured' do
    stub_no_translation
    llm = double(configured?: true)
    allow(llm).to receive(:chat).and_return({ ok: true, message: 'Halo! Selamat datang...', error: nil })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    allow(assistant).to receive(:config).and_return({ 'instructions' => 'You are Marine.' })
    result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'haloo')

    expect(payload).to include(
      'response' => 'Halo! Selamat datang...',
      'action' => 'reply',
      'agent_name' => 'Marine Bot',
      'source_type' => 'llm_fallback',
      'fallback_reason' => 'no_confident_cell_match'
    )
  end

  it 'falls back to handoff when LLM is configured but returns an error' do
    stub_no_translation
    llm = double(configured?: true)
    allow(llm).to receive(:chat).and_return({ ok: false, message: nil, error: 'API timeout' })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    allow(assistant).to receive(:config).and_return({ 'instructions' => 'You are Marine.' })
    result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'unknown')

    expect(payload).to include('action' => 'handoff', 'action_reason' => 'no_confident_cell_match')
  end

  it 'includes language/translation metadata without mutating citations' do
    stub_no_translation
    response = Marine::AssistantResponse.new(id: 9, question: 'Hi', answer: 'Hello!')
    result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 0.9)
    allow(knowledge_base).to receive(:retrieve).and_return(result)

    payload = generator.generate(additional_message: 'Hi')

    expect(payload).to include(
      'detected_language' => 'en',
      'query_language' => 'en',
      'translation_applied' => false,
      'response_translation_applied' => false,
      'translated_query' => nil,
      'translation_error' => nil
    )
    expect(payload['citations']).to eq(result.citations)
  end

  it 'retrieves with the translated query and translates the answer back' do
    allow(Marine::Llm::TranslateQueryService).to receive(:new).and_return(
      double(call: { text: 'Where is my order', source_language: 'id', translated: true, error: nil })
    )
    allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(
      double(call: { text: 'Pesanan Anda dalam perjalanan', source_language: 'en', target_language: 'id', translated: true, error: nil })
    )
    response = Marine::AssistantResponse.new(id: 9, question: 'Where is my order', answer: 'Your order is on the way')
    result = Marine::Cell::RetrievalResult.new(responses: [response], confidence: 0.9)
    allow(knowledge_base).to receive(:retrieve).with('Where is my order', limit: 1).and_return(result)

    payload = generator.generate(additional_message: 'Pesanan saya di mana')

    expect(payload).to include(
      'response' => 'Pesanan Anda dalam perjalanan',
      'query_language' => 'id',
      'response_language' => 'id',
      'translated_query' => 'Where is my order',
      'translation_applied' => true,
      'response_translation_applied' => true
    )
  end

  it 'does not block retrieval or handoff when Marine LLM is unconfigured' do
    allow(Marine::Llm::Config).to receive(:configured?).and_return(false)
    result = Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match')
    allow(knowledge_base).to receive(:retrieve).with('unknown', limit: 1).and_return(result)

    payload = generator.generate(additional_message: 'unknown')

    expect(payload).to include('action' => 'handoff', 'action_reason' => 'no_confident_cell_match')
    expect(payload).to have_key('translation_applied')
  end
end
