# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::ProcessJob do
  let(:account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }

  # The extraction/OCR pipeline itself is covered by the extractor specs; here we drive
  # the job with a stubbed ExtractionService so we never need Poppler/Tesseract and can
  # focus on the job's persistence, idempotency, isolation and no-op behavior.
  let(:result) do
    Marine::Documents::Sop::ExtractionService::Result.new(
      content: "Extracted SOP body.\n\nSecond paragraph.",
      processing_method: 'pdf_text',
      page_count: 2
    )
  end

  def sop_document
    create(:marine_document, :sop_document, assistant: assistant, status: :in_progress, sync_status: :syncing, content: nil)
  end

  def stub_extraction(returning: result)
    service = instance_double(Marine::Documents::Sop::ExtractionService, call: returning)
    allow(Marine::Documents::Sop::ExtractionService).to receive(:new).and_return(service)
    service
  end

  describe 'queue isolation' do
    it 'enqueues onto the dedicated marine_sop queue (never the shared low queue)' do
      expect(described_class.new.queue_name).to eq('marine_sop')
    end
  end

  describe 'successful extraction' do
    it 'atomically stores content, method, page_count, fingerprint and the synced/available state' do
      stub_extraction
      document = sop_document

      described_class.perform_now(document)
      document.reload

      expect(document.content).to eq(result.content)
      expect(document.status).to eq('available')
      expect(document.sync_status).to eq('synced')
      expect(document.processing_method).to eq('pdf_text')
      expect(document.page_count).to eq(2)
      expect(document.content_fingerprint).to eq(Digest::SHA256.hexdigest(result.content))
      expect(document.last_sync_error_code).to be_nil
      expect(document.source_file).to be_attached
    end

    it 'enqueues Commit 1D indexing with the exact fingerprint without creating responses inline' do
      stub_extraction
      document = sop_document
      fingerprint = Digest::SHA256.hexdigest(result.content)

      expect do
        expect { described_class.perform_now(document) }.not_to change(Marine::AssistantResponse, :count)
      end.to have_enqueued_job(Marine::Documents::ResponseBuilderJob).with(document, fingerprint)

      expect(document.reload.indexing_status).to eq('pending')
    end

    it 'keeps extracted content synced and records a stable code if indexing enqueue fails' do
      stub_extraction
      document = sop_document
      allow(Marine::Documents::ResponseBuilderJob).to receive(:perform_later)
        .and_raise(StandardError, '/secret/path broker raw message')
      expect(Rails.logger).to receive(:error) do |payload|
        expect(payload).to include('marine.sop.index_enqueue_error', 'StandardError')
        expect(payload).not_to include('secret', 'raw message')
      end

      expect { described_class.perform_now(document) }.not_to raise_error

      document.reload
      expect(document).to be_sync_synced
      expect(document).to be_available
      expect(document.content).to eq(result.content)
      expect(document.indexing_status).to eq('failed')
      expect(document.indexing_error_code).to eq('sop_index_enqueue_failed')
    end
  end

  describe 'idempotent reprocessing' do
    it 'keeps content, fingerprint and synced state stable across a re-run (no duplication)' do
      stub_extraction
      document = sop_document
      described_class.perform_now(document)
      first = document.reload.attributes.slice('content', 'status', 'sync_status', 'metadata')

      expect { described_class.perform_now(document) }
        .not_to change(Marine::Document, :count)
      document.reload
      expect(document.content).to eq(first['content'])
      expect(document.status).to eq('available')
      expect(document.sync_status).to eq('synced')
      expect(document.content_fingerprint).to eq(Digest::SHA256.hexdigest(result.content))
    end
  end

  describe 'stale / concurrent run' do
    it 'yields to a newer file and never overwrites content when the attached blob changed' do
      document = sop_document
      # The extraction "succeeds" for the blob we started with, but by the time we save a
      # newer upload has replaced the attachment: the older run must not clobber it.
      service = instance_double(Marine::Documents::Sop::ExtractionService)
      allow(Marine::Documents::Sop::ExtractionService).to receive(:new).and_return(service)
      allow(service).to receive(:call) do
        document.source_file.attach(
          io: StringIO.new('%PDF-1.4 newer upload'), filename: 'sop.pdf', content_type: 'application/pdf'
        )
        result
      end

      described_class.perform_now(document)
      document.reload
      expect(document.content).to be_nil
    end
  end

  describe 'stable sanitized failure' do
    it 'marks the document failed with only the stable code and retains the original file' do
      service = instance_double(Marine::Documents::Sop::ExtractionService)
      allow(Marine::Documents::Sop::ExtractionService).to receive(:new).and_return(service)
      allow(service).to receive(:call).and_raise(Marine::Documents::Errors::SopOcrTimeoutError)

      document = sop_document
      described_class.perform_now(document)
      document.reload

      expect(document.sync_status).to eq('failed')
      expect(document.last_sync_error_code).to eq('sop_ocr_timeout')
      expect(document.content).to be_nil
      expect(document.source_file).to be_attached
    end

    it 'collapses an unexpected StandardError to sop_extraction_failed and logs only a tag + error_class' do
      service = instance_double(Marine::Documents::Sop::ExtractionService)
      allow(Marine::Documents::Sop::ExtractionService).to receive(:new).and_return(service)
      allow(service).to receive(:call).and_raise(RuntimeError, '/secret/path/key=abc raw stderr')

      expect(Rails.logger).to receive(:error) do |payload|
        parsed = JSON.parse(payload)
        expect(parsed['error_class']).to eq('RuntimeError')
        expect(payload).not_to include('secret')
        expect(payload).not_to include('raw stderr')
      end

      document = sop_document
      expect { described_class.perform_now(document) }.not_to raise_error
      document.reload

      expect(document.sync_status).to eq('failed')
      expect(document.last_sync_error_code).to eq('sop_extraction_failed')
      expect(document.content).to be_nil
    end
  end

  describe 'stale / concurrent failure' do
    it 'does not mark a document failed after its source_file blob was replaced by a newer run' do
      document = sop_document
      # The old extraction FAILS, but by the time we persist the failure a newer upload
      # has replaced the attachment: the stale failed run must not clobber it.
      service = instance_double(Marine::Documents::Sop::ExtractionService)
      allow(Marine::Documents::Sop::ExtractionService).to receive(:new).and_return(service)
      allow(service).to receive(:call) do
        document.source_file.attach(
          io: StringIO.new('%PDF-1.4 newer upload'), filename: 'sop.pdf', content_type: 'application/pdf'
        )
        raise Marine::Documents::Errors::SopOcrTimeoutError
      end

      described_class.perform_now(document)
      document.reload

      expect(document.sync_status).not_to eq('failed')
      expect(document.last_sync_error_code).to be_nil
    end
  end

  describe 'run token concurrency (same file, ordered runs)' do
    it 'does not overwrite content when a newer run re-claimed the document during extraction' do
      document = sop_document
      service = instance_double(Marine::Documents::Sop::ExtractionService)
      allow(Marine::Documents::Sop::ExtractionService).to receive(:new).and_return(service)
      # Same blob, but a newer run re-stamps the run token mid-extraction: this older
      # success must yield rather than clobber the newer run.
      allow(service).to receive(:call) do
        Marine::Document.find(document.id).update!(sync_run_token: 'newer-run-token')
        result
      end

      described_class.perform_now(document)
      document.reload

      expect(document.content).to be_nil
      expect(document.sync_run_token).to eq('newer-run-token')
    end

    it 'does not fail a document that a newer run already synced during extraction' do
      document = sop_document
      service = instance_double(Marine::Documents::Sop::ExtractionService)
      allow(Marine::Documents::Sop::ExtractionService).to receive(:new).and_return(service)
      allow(service).to receive(:call) do
        Marine::Document.find(document.id).update!(
          content: 'newer good content', status: :available, sync_status: :synced,
          content_fingerprint: 'newer-fp', sync_run_token: 'newer-run-token'
        )
        raise Marine::Documents::Errors::SopOcrTimeoutError
      end

      described_class.perform_now(document)
      document.reload

      expect(document.sync_status).to eq('synced')
      expect(document.content).to eq('newer good content')
      expect(document.last_sync_error_code).to be_nil
    end

    it 'preserves the last good synced content when a later same-file run fails' do
      stub_extraction
      document = sop_document
      described_class.perform_now(document)
      good = document.reload.content
      expect(document.sync_status).to eq('synced')

      failing = instance_double(Marine::Documents::Sop::ExtractionService)
      allow(Marine::Documents::Sop::ExtractionService).to receive(:new).and_return(failing)
      allow(failing).to receive(:call).and_raise(Marine::Documents::Errors::SopOcrTimeoutError)

      described_class.perform_now(document)
      document.reload

      expect(document.content).to eq(good)
      expect(document.status).to eq('available')
      expect(document.sync_status).to eq('synced')
      expect(document.last_sync_error_code).to be_nil
    end
  end

  describe 'non-SOP documents' do
    it 'is a strict no-op for a product_catalog (never extracts, never changes state)' do
      expect(Marine::Documents::Sop::ExtractionService).not_to receive(:new)
      document = create(:marine_document, :product_catalog, assistant: assistant)

      expect { described_class.perform_now(document) }.not_to(change { document.reload.attributes })
    end

    it 'does not route website documents into the SOP pipeline' do
      expect(Marine::Documents::Sop::ExtractionService).not_to receive(:new)
      document = create(:marine_document, :website, assistant: assistant)

      described_class.perform_now(document)
      expect(document.reload.content).to be_nil
    end
  end
end
