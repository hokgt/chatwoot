# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::ProductCatalogService, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }
  let(:family_code) { 'FAM-001' }

  # Stubbed repository so specs never touch the external catalog DB.
  let(:repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }

  let(:pdf_bytes) { ("%PDF-1.4\n#{('a' * 500)}").b }

  def upload_for(bytes, filename: 'catalog.pdf', content_type: 'application/pdf')
    file = Tempfile.new(['marine-catalog', File.extname(filename)])
    file.binmode
    file.write(bytes)
    file.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: filename, type: content_type)
  end

  def build_service(upload:, replace: false, primary_catalog: true, target_account: account, target_assistant: assistant)
    described_class.new(
      account: target_account,
      assistant: target_assistant,
      product_family_code: family_code,
      upload: upload,
      primary_catalog: primary_catalog,
      replace: replace,
      repository: repository
    )
  end

  before do
    allow(repository).to receive(:exists?).with(family_code).and_return(true)
  end

  describe 'creating the first primary catalog' do
    it 'stores the exact original bytes, checksum, MIME, size and marks it primary' do
      upload = upload_for(pdf_bytes)
      document = build_service(upload: upload).call

      expect(document).to be_persisted
      expect(document.source_kind).to eq('product_catalog')
      expect(document.primary_catalog).to be(true)
      expect(document.product_family_code).to eq(family_code)

      blob = document.source_file.blob
      expect(blob.byte_size).to eq(pdf_bytes.bytesize)
      expect(blob.content_type).to eq('application/pdf')
      expect(blob.checksum).to eq(OpenSSL::Digest::MD5.base64digest(pdf_bytes))
      expect(document.source_file.download.b).to eq(pdf_bytes)
    end

    it 'marks the blob to skip ActiveStorage analysis and enqueues no Marine/analysis job' do
      expect(Marine::Documents::ResponseBuilderJob).not_to receive(:perform_later)
      # A marked blob short-circuits ActiveStorage::Attachment#analyze_blob_later before
      # blob.analyze_later (which is what would enqueue ActiveStorage::AnalyzeJob) is called.
      expect_any_instance_of(ActiveStorage::Blob).not_to receive(:analyze_later)

      document = build_service(upload: upload_for(pdf_bytes)).call

      key = Wijaya::Marine::ActiveStorageAnalysisGuard::SKIP_METADATA_KEY
      expect(document.source_file.blob.metadata[key]).to be(true)
    end
  end

  describe 'duplicate without explicit replacement' do
    it 'raises PrimaryConflictError and leaves the existing catalog untouched' do
      existing = build_service(upload: upload_for(pdf_bytes)).call
      existing_blob_id = existing.source_file.blob.id

      expect { build_service(upload: upload_for(pdf_bytes), replace: false).call }
        .to raise_error(Marine::Documents::Errors::PrimaryConflictError)

      existing.reload
      expect(existing.source_file.blob.id).to eq(existing_blob_id)
      expect(assistant.documents.where(source_kind: 'product_catalog').count).to eq(1)
    end

    it 'does not upload new bytes when it can fail fast' do
      build_service(upload: upload_for(pdf_bytes)).call
      expect do
        expect { build_service(upload: upload_for(pdf_bytes)).call }
          .to raise_error(Marine::Documents::Errors::PrimaryConflictError)
      end.not_to change(ActiveStorage::Blob, :count)
    end
  end

  describe 'explicit replacement' do
    it 'replaces the primary catalog and purges the OLD blob only after commit' do
      first = build_service(upload: upload_for(pdf_bytes)).call
      old_blob = first.source_file.blob
      new_bytes = ("%PDF-1.4\n#{('b' * 900)}").b

      replacement = build_service(upload: upload_for(new_bytes), replace: true).call

      expect(replacement.id).not_to eq(first.id)
      expect(assistant.documents.where(source_kind: 'product_catalog', primary_catalog: true).count).to eq(1)
      expect(replacement.source_file.download.b).to eq(new_bytes)
      expect(Marine::Document.exists?(first.id)).to be(false)
      expect(ActiveStorage::Blob.exists?(old_blob.id)).to be(false)
    end

    it 'still succeeds when the OLD blob purge fails after the replacement commits' do
      first = build_service(upload: upload_for(pdf_bytes)).call
      old_blob = first.source_file.blob
      new_bytes = ("%PDF-1.4\n#{('c' * 700)}").b

      # Fail only the superseded blob's post-commit purge; everything else is real.
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_wrap_original do |method, *args|
        raise StandardError, 'purge boom' if method.receiver.id == old_blob.id

        method.call(*args)
      end

      replacement = nil
      expect { replacement = build_service(upload: upload_for(new_bytes), replace: true).call }
        .not_to raise_error

      expect(assistant.documents.where(source_kind: 'product_catalog', primary_catalog: true).count).to eq(1)
      expect(replacement.source_file.download.b).to eq(new_bytes)
      expect(ActiveStorage::Blob.exists?(replacement.source_file.blob.id)).to be(true)
      expect(Marine::Document.exists?(first.id)).to be(false)
    end
  end

  describe 'replacement failure preserves the old catalog' do
    it 'rolls back and cleans up the new blob when the save fails' do
      first = build_service(upload: upload_for(pdf_bytes)).call
      old_blob_id = first.source_file.blob.id

      allow_any_instance_of(Marine::Document).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(Marine::Document.new))

      expect do
        expect { build_service(upload: upload_for(pdf_bytes), replace: true).call }
          .to raise_error(ActiveRecord::RecordInvalid)
      end.not_to change(ActiveStorage::Blob, :count)

      first.reload
      expect(first.source_file.blob.id).to eq(old_blob_id)
      expect(Marine::Document.exists?(first.id)).to be(true)
    end
  end

  describe 'account isolation' do
    it 'raises AccountMismatchError when the assistant belongs to another account' do
      other_account = create(:account)
      expect { build_service(upload: upload_for(pdf_bytes), target_account: other_account).call }
        .to raise_error(Marine::Documents::Errors::AccountMismatchError)
      expect(assistant.documents.count).to eq(0)
    end
  end

  describe 'unknown product family' do
    it 'raises UnknownFamilyError without uploading bytes' do
      allow(repository).to receive(:exists?).with(family_code).and_return(false)
      expect do
        expect { build_service(upload: upload_for(pdf_bytes)).call }
          .to raise_error(Marine::Documents::Errors::UnknownFamilyError)
      end.not_to change(ActiveStorage::Blob, :count)
    end
  end

  describe 'invalid upload' do
    it 'raises InvalidFileError for a spoofed file and stores nothing' do
      spoofed = upload_for("\x89PNG\r\n\x1A\n".b + ('a' * 100), filename: 'catalog.pdf', content_type: 'application/pdf')
      expect do
        expect { build_service(upload: spoofed).call }
          .to raise_error(Marine::Documents::Errors::InvalidFileError)
      end.not_to change(ActiveStorage::Blob, :count)
    end

    it 'rejects a non-primary intent deterministically' do
      expect { build_service(upload: upload_for(pdf_bytes), primary_catalog: false).call }
        .to raise_error(Marine::Documents::Errors::InvalidFileError)
    end
  end

  describe 'catalog unavailable' do
    it 'propagates CatalogUnavailableError from the repository' do
      allow(repository).to receive(:exists?).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)
      expect { build_service(upload: upload_for(pdf_bytes)).call }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
    end
  end
end
