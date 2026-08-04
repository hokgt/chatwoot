# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::UpdateEmbeddingJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }

  before { clear_enqueued_jobs }

  def build_response(attributes = {})
    Marine::AssistantResponse.new({ assistant: assistant, account: account,
                                    question: 'Question', answer: 'Answer' }.merge(attributes))
  end

  it 'enqueues only the response GlobalID and never serializes question or answer text' do
    response = build_response(question: 'CONFIDENTIAL QUESTION', answer: 'CONFIDENTIAL ANSWER')

    expect { response.save! }.to have_enqueued_job(described_class).with(response)

    job = enqueued_jobs.find { |entry| entry[:job] == described_class }
    serialized = job.fetch(:args).to_json
    expect(serialized).not_to include('CONFIDENTIAL QUESTION', 'CONFIDENTIAL ANSWER')
  end

  it 'computes embedding text inside the worker' do
    response = build_response(question: 'Safe question', answer: 'Safe answer').tap(&:save!)
    clear_enqueued_jobs
    service = instance_double(Marine::Llm::EmbeddingService)
    allow(Marine::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(service)
    expect(service).to receive(:get_embedding).with('Safe question: Safe answer').and_return(nil)

    described_class.perform_now(response)
  end

  it 'loads current text for a matching non-secret SOP fingerprint context' do
    fingerprint = Digest::SHA256.hexdigest('SOP body')
    document = create(:marine_document, :sop_document, assistant: assistant, content: 'SOP body',
                                                       status: :available, sync_status: :synced,
                                                       metadata: { 'content_fingerprint' => fingerprint })
    response = build_response(documentable: document, question: 'SOP question', answer: 'SOP answer',
                              skip_embedding_enqueue: true).tap(&:save!)
    service = instance_double(Marine::Llm::EmbeddingService)
    allow(Marine::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(service)
    expect(service).to receive(:get_embedding).with('SOP question: SOP answer').and_return(nil)

    described_class.perform_now(response, { 'expected_fingerprint' => fingerprint })
  end

  it 'skips an embedding job whose SOP fingerprint became stale' do
    fingerprint = Digest::SHA256.hexdigest('Old SOP body')
    document = create(:marine_document, :sop_document, assistant: assistant, content: 'New SOP body',
                                                       status: :available, sync_status: :synced,
                                                       metadata: { 'content_fingerprint' => Digest::SHA256.hexdigest('New SOP body') })
    response = build_response(documentable: document, skip_embedding_enqueue: true).tap(&:save!)
    expect(Marine::Llm::EmbeddingService).not_to receive(:new)

    described_class.perform_now(response, { 'expected_fingerprint' => fingerprint })
  end

  it 'does not enqueue an embedding job when a response is destroyed' do
    response = build_response.tap(&:save!)
    clear_enqueued_jobs

    expect { response.destroy! }.not_to have_enqueued_job(described_class)
  end

  it 'remains compatible with already-enqueued legacy jobs that contain a second argument' do
    response = build_response.tap(&:save!)
    clear_enqueued_jobs
    service = instance_double(Marine::Llm::EmbeddingService)
    allow(Marine::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(service)
    expect(service).to receive(:get_embedding).with('legacy text').and_return(nil)

    described_class.perform_now(response, 'legacy text')
  end
end
