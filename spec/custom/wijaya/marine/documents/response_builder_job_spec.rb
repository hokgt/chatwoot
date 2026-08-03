# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::ResponseBuilderJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }

  def fingerprint(content)
    Digest::SHA256.hexdigest(content)
  end

  DEFAULT_CONTENT = "#{'A' * 1_100}.\n\n#{'B' * 1_100}.".freeze

  def synced_sop(content: DEFAULT_CONTENT)
    fp = fingerprint(content)
    document = create(:marine_document, :sop_document, assistant: assistant, content: content,
                      status: :available, sync_status: :synced,
                      metadata: { 'content_fingerprint' => fp })
    clear_enqueued_jobs
    [document, fp]
  end

  it 'creates ordered approved citation-ready chunks and one embedding job per chunk' do
    document, fp = synced_sop

    expect { described_class.perform_now(document, fp) }
      .to have_enqueued_job(Marine::Llm::UpdateEmbeddingJob).at_least(:once)

    responses = document.responses.order(:id).to_a
    expect(responses.length).to be > 1
    expect(responses.map(&:question)).to eq(
      responses.each_index.map { |index| "Marine SOP Document (Part #{index + 1} of #{responses.length})" }
    )
    expect(responses).to all(have_attributes(status: 'approved', assistant_id: assistant.id,
                                             account_id: account.id, documentable: document))
    expect(enqueued_jobs.count { |job| job[:job] == Marine::Llm::UpdateEmbeddingJob }).to eq(responses.length)

    citation = Marine::Cell::CitationBuilder.build([responses.first]).first
    expect(citation).to include(source_type: 'document', document_id: document.id,
                                document_name: 'Marine SOP Document')
    document.reload
    expect(document.indexing_status).to eq('indexed')
    expect(document.indexed_fingerprint).to eq(fp)
    expect(document.indexed_chunk_count.to_i).to eq(responses.length)
    expect(document.indexing_error_code).to be_nil
  end

  it 'is a true no-op for an unchanged retry and enqueues no duplicate embeddings' do
    document, fp = synced_sop
    described_class.perform_now(document, fp)
    ids = document.responses.order(:id).ids
    clear_enqueued_jobs

    expect { described_class.perform_now(document, fp) }
      .not_to have_enqueued_job(Marine::Llm::UpdateEmbeddingJob)
    expect(document.responses.order(:id).ids).to eq(ids)
  end

  it 'no-ops for a stale fingerprint without touching current chunks' do
    document, fp = synced_sop
    described_class.perform_now(document, fp)
    rows = document.responses.order(:id).pluck(:id, :question, :answer)
    clear_enqueued_jobs

    described_class.perform_now(document, 'stale-fingerprint')

    expect(document.responses.order(:id).pluck(:id, :question, :answer)).to eq(rows)
    expect(enqueued_jobs).to be_empty
  end

  it 'atomically replaces only this document chunks when content changes' do
    document, old_fp = synced_sop
    described_class.perform_now(document, old_fp)
    old_ids = document.responses.ids
    other = create(:marine_document, :website, assistant: assistant, content: 'other body')
    other_response = other.responses.create!(question: 'Other', answer: 'Keep me', assistant: assistant, account: account)
    clear_enqueued_jobs

    new_content = 'New procedure. ' * 180
    new_fp = fingerprint(new_content)
    document.update!(content: new_content, content_fingerprint: new_fp, indexing_status: 'pending')
    described_class.perform_now(document, new_fp)

    expect(document.responses.ids).not_to match_array(old_ids)
    expect(document.responses.pluck(:answer).join(' ')).to include('New procedure')
    expect(Marine::AssistantResponse.exists?(other_response.id)).to be(true)
    expect(document.reload.indexed_fingerprint).to eq(new_fp)
  end

  it 'rolls replacement back and preserves prior good chunks on a create failure' do
    document, old_fp = synced_sop
    described_class.perform_now(document, old_fp)
    old_rows = document.responses.order(:id).pluck(:id, :question, :answer)
    clear_enqueued_jobs

    new_content = 'Replacement body. ' * 180
    new_fp = fingerprint(new_content)
    document.update!(content: new_content, content_fingerprint: new_fp, indexing_status: 'pending')
    allow_any_instance_of(Marine::AssistantResponse).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)

    expect { described_class.perform_now(document, new_fp) }.not_to raise_error

    expect(document.responses.order(:id).pluck(:id, :question, :answer)).to eq(old_rows)
    expect(document.reload.indexing_status).to eq('failed')
    expect(document.indexing_error_code).to eq('sop_index_failed')
    expect(enqueued_jobs).to be_empty
  end

  it 'requires synced available content and safely no-ops after deletion' do
    document, fp = synced_sop
    document.update!(sync_status: :failed)
    expect { described_class.perform_now(document, fp) }.not_to change(Marine::AssistantResponse, :count)

    document.destroy!
    expect { described_class.perform_now(document, fp) }.not_to raise_error
  end

  it 'bounds and sanitizes titles without exposing body text' do
    secret = 'CONFIDENTIAL BODY ' * 100
    document, fp = synced_sop(content: secret)
    document.update!(name: "N\n#{'界' * 250}")

    described_class.perform_now(document, fp)

    expect(document.responses).to all(satisfy { |response| response.question.scan(/\X/).length <= 255 })
    expect(document.responses.pluck(:question).join).not_to include('CONFIDENTIAL')
    expect(document.responses.pluck(:question).join).not_to include("\n")
  end

  it 'keeps website single-response behavior and product catalogs are strict no-ops' do
    website = create(:marine_document, :website, assistant: assistant, content: 'Website knowledge')
    clear_enqueued_jobs
    described_class.perform_now(website)
    expect(website.responses.count).to eq(1)
    expect(website.responses.first.answer).to eq('Website knowledge')

    catalog = create(:marine_document, :product_catalog, assistant: assistant)
    expect { described_class.perform_now(catalog) }.not_to change(Marine::AssistantResponse, :count)
  end
end
