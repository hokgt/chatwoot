# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::CreateSopService, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }

  let(:pdf_bytes) { ("%PDF-1.4\n" + ('a' * 500)).b }

  def upload_for(bytes, filename: 'procedure.pdf', content_type: 'application/pdf')
    file = Tempfile.new(['marine-sop', File.extname(filename)])
    file.binmode
    file.write(bytes)
    file.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: filename, type: content_type)
  end

  def build_service(upload:, name: nil, target_account: account, target_assistant: assistant)
    described_class.new(account: target_account, assistant: target_assistant, upload: upload, name: name)
  end

  describe 'creating an SOP document' do
    it 'stores the exact original bytes, checksum, MIME, size and original filename' do
      document = build_service(upload: upload_for(pdf_bytes)).call

      expect(document).to be_persisted
      expect(document.source_kind).to eq('sop_document')

      blob = document.source_file.blob
      expect(blob.byte_size).to eq(pdf_bytes.bytesize)
      expect(blob.content_type).to eq('application/pdf')
      expect(blob.checksum).to eq(OpenSSL::Digest::MD5.base64digest(pdf_bytes))
      expect(document.source_file.download.b).to eq(pdf_bytes)

      expect(document.original_filename).to eq('procedure.pdf')
      expect(document.detected_content_type).to eq('application/pdf')
      expect(document.original_byte_size).to eq(pdf_bytes.bytesize)
    end

    it 'creates the approved initial processing state with no url/family/content' do
      document = build_service(upload: upload_for(pdf_bytes)).call

      expect(document.status).to eq('in_progress')
      expect(document.sync_status).to eq('syncing')
      expect(document.content).to be_nil
      expect(document.external_link).to be_nil
      expect(document.product_family_code).to be_nil
      expect(document.primary_catalog).to be(false)
    end

    it 'enqueues the SOP processing job (and never the response builder / analysis)' do
      expect(Marine::Documents::ResponseBuilderJob).not_to receive(:perform_later)
      expect_any_instance_of(ActiveStorage::Blob).not_to receive(:analyze_later)

      document = nil
      expect do
        document = build_service(upload: upload_for(pdf_bytes)).call
      end.to have_enqueued_job(Marine::Documents::ProcessJob)

      key = Wijaya::Marine::ActiveStorageAnalysisGuard::SKIP_METADATA_KEY
      expect(document.source_file.blob.metadata[key]).to be(true)
    end

    it 'does not create any AssistantResponse' do
      expect { build_service(upload: upload_for(pdf_bytes)).call }
        .not_to change(Marine::AssistantResponse, :count)
    end

    it 'derives the name from the sanitized filename when none is given' do
      document = build_service(upload: upload_for(pdf_bytes, filename: 'Safety SOP.pdf')).call
      expect(document.name).to eq('Safety SOP.pdf')
    end

    it 'sanitizes and truncates a client-supplied name' do
      raw = "Bad\u0000Na\tme#{"\x07"}" + ('z' * 400)
      document = build_service(upload: upload_for(pdf_bytes), name: raw).call

      expect(document.name.length).to eq(described_class::MAX_NAME_LENGTH)
      expect(document.name).not_to include("\u0000")
      expect(document.name).not_to include("\x07")
      expect(document.name).to start_with('BadName')
    end
  end

  describe 'validation' do
    it 'raises InvalidFileError for a spoofed file and stores nothing' do
      spoofed = upload_for("\x89PNG\r\n\x1A\n".b + ('a' * 100), filename: 'procedure.pdf', content_type: 'application/pdf')
      expect do
        expect { build_service(upload: spoofed).call }
          .to raise_error(Marine::Documents::Errors::InvalidFileError)
      end.not_to change(ActiveStorage::Blob, :count)
    end
  end

  describe 'account isolation' do
    it 'raises AccountMismatchError when the assistant belongs to another account' do
      other = create(:account)
      expect { build_service(upload: upload_for(pdf_bytes), target_account: other).call }
        .to raise_error(Marine::Documents::Errors::AccountMismatchError)
      expect(assistant.documents.count).to eq(0)
    end
  end

  describe 'transaction cleanup' do
    it 'purges the new orphan blob when persistence fails' do
      allow_any_instance_of(Marine::Document).to receive(:save!)
        .and_raise(ActiveRecord::RecordInvalid.new(Marine::Document.new))

      expect do
        expect { build_service(upload: upload_for(pdf_bytes)).call }
          .to raise_error(ActiveRecord::RecordInvalid)
      end.not_to change(ActiveStorage::Blob, :count)
    end

    it 'does not mask the original persistence error when the orphan purge itself fails' do
      allow_any_instance_of(Marine::Document).to receive(:save!)
        .and_raise(ActiveRecord::RecordInvalid.new(Marine::Document.new))
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_raise(StandardError, 'purge boom')

      expect(Rails.logger).to receive(:error) do |payload|
        parsed = JSON.parse(payload)
        expect(parsed['tag']).to eq('marine.sop.orphan_purge_failed')
        expect(parsed['error_class']).to eq('StandardError')
        expect(payload).not_to include('purge boom')
      end

      # The ORIGINAL RecordInvalid surfaces, not the purge failure.
      expect { build_service(upload: upload_for(pdf_bytes)).call }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe 'enqueue failure' do
    it 'retains the original file and marks the document failed with a stable code' do
      allow(Marine::Documents::ProcessJob).to receive(:perform_later).and_raise(StandardError, 'broker down')

      document = build_service(upload: upload_for(pdf_bytes)).call

      expect(document.source_file).to be_attached
      expect(document.sync_status).to eq('failed')
      expect(document.last_sync_error_code).to eq('sop_enqueue_failed')
    end
  end
end
