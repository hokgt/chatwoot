# frozen_string_literal: true

require 'rails_helper'

# Regression: Marine answered operational-hours questions with a "no hours / contact a
# human" fallback even though the hours live in the knowledge base. Root cause: the RAG
# grounding block was built from a query-independent, per-entry-truncated slice of the KB,
# so an hours fact sitting deep inside a matched document chunk never reached the generator.
# The grounding must instead include — in full — the record retrieval actually matched for
# the question.
#
# These specs use synthetic KB fixtures with ARBITRARY hours (two unrelated schedules) and
# the REAL retriever, proving the hours are surfaced dynamically with no hardcoded schedule,
# business name, or question phrasing.
RSpec.describe Marine::Charge::ResponseGenerator, 'operational-hours grounding' do
  let(:account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }

  before do
    # Keep translation a no-op so the English fixtures/query drive the real retriever directly.
    allow(Marine::Llm::TranslateQueryService).to receive(:new).and_return(
      double(call: { text: nil, source_language: 'en', translated: false, error: nil })
    )
    allow(Marine::Llm::TranslateResponseService).to receive(:new).and_return(
      double(call: { text: nil, source_language: 'en', target_language: 'en', translated: false, error: nil })
    )
  end

  def create_response(question:, answer:, documentable: nil)
    Marine::AssistantResponse.create!(
      assistant: assistant, question: question, answer: answer,
      status: :approved, documentable: documentable, skip_embedding_enqueue: true
    )
  end

  # The hours sit AFTER the per-entry truncation cutoff inside a document chunk, exactly like
  # the production chunk that regressed, so a query-independent / truncating grounding block
  # drops them while the record is still the strongest retrieval match for an hours question.
  def seed_knowledge_base(schedule)
    document = create(:marine_document, assistant: assistant, name: 'Company Handbook')
    filler = 'General background about the company and its history. ' * 12
    create_response(
      question: 'Operating hours and schedule',
      answer: "#{filler}\nOur office is open #{schedule}.",
      documentable: document
    )
    # A little breadth so the grounding fill is realistic.
    create_response(question: 'What is the minimum order?', answer: 'The minimum order is 10 units.')
  end

  def generate_hours_reply(question:, schedule:)
    seed_knowledge_base(schedule)

    captured_system = nil
    llm = double('llm', configured?: true)
    allow(llm).to receive(:chat) do |args|
      captured_system = args[:system]
      { ok: true, message: 'Sure — here are our hours.', error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)

    payload = described_class.new(assistant: assistant).generate(additional_message: question)
    [captured_system, payload]
  end

  # Two arbitrary, unrelated schedules prove the hours are read from the fixture dynamically,
  # not from any hardcoded constant, keyword list, or transcript-specific behavior.
  {
    'weekday daytime' => 'Monday to Friday from 09:00 to 18:00',
    'compressed hours' => 'Tuesday to Saturday from 07:30 to 15:30'
  }.each do |label, schedule|
    it "grounds the LLM in the KB hours (#{label}) for a natural hours question" do
      system, payload = generate_hours_reply(question: 'What are your operating hours?', schedule: schedule)

      expect(system).to be_present
      expect(system).to include(schedule)
      # Provenance is preserved: the matched record still routes via grounded RAG and is cited.
      expect(payload['source_type']).to eq('llm_rag')
      expect(payload['response_ids']).to be_present
    end
  end
end
