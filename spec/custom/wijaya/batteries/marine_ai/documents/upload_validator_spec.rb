# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::UploadValidator, type: :model do
  PDF_MAGIC = "%PDF-1.4\n".b
  PNG_MAGIC = "\x89PNG\r\n\x1A\n".b
  JPEG_MAGIC = "\xFF\xD8\xFF\xE0".b

  def upload_for(bytes, filename:, content_type:)
    file = Tempfile.new(['marine-upload', File.extname(filename)])
    file.binmode
    file.write(bytes)
    file.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: filename, type: content_type)
  end

  def pad(magic, total_bytes)
    (magic + ('a' * [total_bytes - magic.bytesize, 0].max)).b
  end

  describe 'accepts supported types when extension, MIME, and signature agree' do
    it 'accepts a PDF' do
      upload = upload_for(pad(PDF_MAGIC, 512), filename: 'catalog.pdf', content_type: 'application/pdf')
      result = described_class.new(upload).call
      expect(result.content_type).to eq('application/pdf')
      expect(result.byte_size).to eq(512)
      expect(result.filename).to eq('catalog.pdf')
    end

    it 'accepts a PNG' do
      upload = upload_for(pad(PNG_MAGIC, 256), filename: 'catalog.png', content_type: 'image/png')
      expect(described_class.new(upload).call.content_type).to eq('image/png')
    end

    it 'accepts a JPEG for both .jpg and .jpeg' do
      jpg = upload_for(pad(JPEG_MAGIC, 256), filename: 'catalog.jpg', content_type: 'image/jpeg')
      jpeg = upload_for(pad(JPEG_MAGIC, 256), filename: 'catalog.jpeg', content_type: 'image/jpeg')
      expect(described_class.new(jpg).call.content_type).to eq('image/jpeg')
      expect(described_class.new(jpeg).call.content_type).to eq('image/jpeg')
    end
  end

  describe 'size boundaries' do
    it 'accepts a file of exactly 2 MiB' do
      upload = upload_for(pad(PDF_MAGIC, described_class::MAX_BYTES), filename: 'c.pdf', content_type: 'application/pdf')
      expect(described_class.new(upload).call.byte_size).to eq(described_class::MAX_BYTES)
    end

    it 'rejects a file exceeding 2 MiB by one byte' do
      upload = upload_for(pad(PDF_MAGIC, described_class::MAX_BYTES + 1), filename: 'c.pdf', content_type: 'application/pdf')
      expect { described_class.new(upload).call }.to raise_error(Marine::Documents::Errors::InvalidFileError)
    end

    it 'rejects an empty file' do
      upload = upload_for(''.b, filename: 'c.pdf', content_type: 'application/pdf')
      expect { described_class.new(upload).call }.to raise_error(Marine::Documents::Errors::InvalidFileError)
    end
  end

  describe 'independent extension / MIME / signature validation' do
    it 'rejects an unsupported extension' do
      upload = upload_for(pad(PDF_MAGIC, 128), filename: 'c.txt', content_type: 'text/plain')
      expect { described_class.new(upload).call }.to raise_error(Marine::Documents::Errors::InvalidFileError)
    end

    it 'rejects a declared MIME that does not match the extension' do
      upload = upload_for(pad(PDF_MAGIC, 128), filename: 'c.pdf', content_type: 'image/png')
      expect { described_class.new(upload).call }.to raise_error(Marine::Documents::Errors::InvalidFileError)
    end

    it 'rejects content whose signature does not match the extension/MIME' do
      upload = upload_for(pad(PNG_MAGIC, 128), filename: 'c.pdf', content_type: 'application/pdf')
      expect { described_class.new(upload).call }.to raise_error(Marine::Documents::Errors::InvalidFileError)
    end

    it 'rejects a spoofed image/jpeg that actually carries PDF bytes' do
      upload = upload_for(pad(PDF_MAGIC, 128), filename: 'c.jpg', content_type: 'image/jpeg')
      expect { described_class.new(upload).call }.to raise_error(Marine::Documents::Errors::InvalidFileError)
    end
  end

  describe 'safety of error messages and IO handling' do
    it 'never leaks the filename or content in the error message' do
      upload = upload_for(pad(PNG_MAGIC, 128), filename: 'super-secret-name.pdf', content_type: 'application/pdf')
      expect { described_class.new(upload).call }.to raise_error(Marine::Documents::Errors::InvalidFileError) do |error|
        expect(error.message).not_to include('super-secret-name')
        expect(error.message).not_to include('PNG')
      end
    end

    it 'rewinds the IO so the caller can store the exact original bytes' do
      bytes = pad(PDF_MAGIC, 300)
      upload = upload_for(bytes, filename: 'c.pdf', content_type: 'application/pdf')
      described_class.new(upload).call
      expect(upload.read.b).to eq(bytes)
    end
  end
end
