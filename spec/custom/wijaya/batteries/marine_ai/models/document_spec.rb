# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Document, type: :model do
  def attach_source_file(document, bytes:, content_type: 'application/pdf', filename: 'file.pdf')
    document.source_file.attach(
      io: StringIO.new('a' * bytes),
      filename: filename,
      content_type: content_type
    )
  end

  describe 'associations' do
    it { is_expected.to belong_to(:assistant).class_name('Marine::Assistant') }
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:responses).class_name('Marine::AssistantResponse').dependent(:destroy) }

    it 'has a source_file attachment' do
      document = build(:marine_document, :product_catalog)
      expect(document.source_file).to be_attached
    end
  end

  describe 'source_kind enum and predicates' do
    it 'defines the three source kinds' do
      expect(described_class.source_kinds).to eq(
        'website' => 'website',
        'product_catalog' => 'product_catalog',
        'sop_document' => 'sop_document'
      )
    end

    it 'exposes predicates per kind' do
      expect(build(:marine_document, :website)).to be_website
      expect(build(:marine_document, :product_catalog)).to be_product_catalog
      expect(build(:marine_document, :sop_document)).to be_sop_document
    end

    it 'defaults to website' do
      expect(described_class.new.source_kind).to eq('website')
    end
  end

  describe '#syncable?' do
    it 'is syncable for website sources' do
      expect(build(:marine_document, :website)).to be_syncable
    end

    it 'is syncable for sop documents' do
      expect(build(:marine_document, :sop_document)).to be_syncable
    end

    it 'is not syncable for product catalogs' do
      expect(build(:marine_document, :product_catalog)).not_to be_syncable
    end
  end

  describe 'source matrix validations' do
    it 'accepts a valid website document' do
      expect(build(:marine_document, :website)).to be_valid
    end

    it 'accepts a valid product catalog document' do
      expect(build(:marine_document, :product_catalog)).to be_valid
    end

    it 'accepts a valid sop document' do
      expect(build(:marine_document, :sop_document)).to be_valid
    end

    context 'when website' do
      it 'requires external_link' do
        document = build(:marine_document, :website, external_link: nil)
        expect(document).not_to be_valid
        expect(document.errors[:external_link]).to be_present
      end

      it 'forbids a source_file' do
        document = build(:marine_document, :website)
        attach_source_file(document, bytes: 10)
        expect(document).not_to be_valid
        expect(document.errors[:source_file]).to be_present
      end

      it 'forbids product_family_code' do
        document = build(:marine_document, :website, product_family_code: 'FAM-999')
        expect(document).not_to be_valid
        expect(document.errors[:product_family_code]).to be_present
      end

      it 'forbids primary_catalog' do
        document = build(:marine_document, :website, primary_catalog: true)
        expect(document).not_to be_valid
        expect(document.errors[:primary_catalog]).to be_present
      end
    end

    context 'when product_catalog' do
      it 'requires a source_file' do
        document = build(:marine_document, :product_catalog)
        document.source_file.detach
        expect(document).not_to be_valid
        expect(document.errors[:source_file]).to be_present
      end

      it 'requires product_family_code' do
        document = build(:marine_document, :product_catalog, product_family_code: nil)
        expect(document).not_to be_valid
        expect(document.errors[:product_family_code]).to be_present
      end

      it 'requires primary_catalog to be true' do
        document = build(:marine_document, :product_catalog, primary_catalog: false)
        expect(document).not_to be_valid
        expect(document.errors[:primary_catalog]).to be_present
      end

      it 'forbids external_link' do
        document = build(:marine_document, :product_catalog, external_link: 'https://example.com')
        expect(document).not_to be_valid
        expect(document.errors[:external_link]).to be_present
      end

      it 'forbids content' do
        document = build(:marine_document, :product_catalog, content: 'inline content')
        expect(document).not_to be_valid
        expect(document.errors[:content]).to be_present
      end
    end

    context 'when sop_document' do
      it 'requires a source_file' do
        document = build(:marine_document, :sop_document)
        document.source_file.detach
        expect(document).not_to be_valid
        expect(document.errors[:source_file]).to be_present
      end

      it 'forbids external_link' do
        document = build(:marine_document, :sop_document, external_link: 'https://example.com')
        expect(document).not_to be_valid
        expect(document.errors[:external_link]).to be_present
      end

      it 'forbids product_family_code' do
        document = build(:marine_document, :sop_document, product_family_code: 'FAM-1')
        expect(document).not_to be_valid
        expect(document.errors[:product_family_code]).to be_present
      end

      it 'forbids primary_catalog' do
        document = build(:marine_document, :sop_document, primary_catalog: true)
        expect(document).not_to be_valid
        expect(document.errors[:primary_catalog]).to be_present
      end
    end
  end

  describe 'uploaded source_file size validation' do
    it 'accepts a file of exactly 2 MiB' do
      document = build(:marine_document, :product_catalog)
      attach_source_file(document, bytes: Marine::Document::MAX_SOURCE_FILE_BYTES)
      expect(document).to be_valid
    end

    it 'rejects a file exceeding 2 MiB by one byte' do
      document = build(:marine_document, :product_catalog)
      attach_source_file(document, bytes: Marine::Document::MAX_SOURCE_FILE_BYTES + 1)
      expect(document).not_to be_valid
      expect(document.errors[:source_file]).to be_present
    end

    it 'rejects an empty file' do
      document = build(:marine_document, :product_catalog)
      attach_source_file(document, bytes: 0)
      expect(document).not_to be_valid
      expect(document.errors[:source_file]).to be_present
    end
  end

  describe 'uploaded source_file content type validation' do
    %w[application/pdf image/jpeg image/png].each do |content_type|
      it "accepts #{content_type}" do
        document = build(:marine_document, :product_catalog)
        attach_source_file(document, bytes: 100, content_type: content_type)
        expect(document).to be_valid
      end
    end

    ['text/plain', 'application/zip', 'image/gif'].each do |content_type|
      it "rejects #{content_type}" do
        document = build(:marine_document, :product_catalog)
        attach_source_file(document, bytes: 100, content_type: content_type)
        expect(document).not_to be_valid
        expect(document.errors[:source_file]).to be_present
      end
    end
  end

  describe 'primary product catalog uniqueness' do
    let(:assistant) { create(:marine_assistant) }

    it 'forbids a second primary catalog for the same assistant and family' do
      create(:marine_document, :product_catalog, assistant: assistant, product_family_code: 'FAM-100')
      duplicate = build(:marine_document, :product_catalog, assistant: assistant, product_family_code: 'FAM-100')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:product_family_code]).to be_present
    end

    it 'allows the same family for a different assistant' do
      other_assistant = create(:marine_assistant)
      create(:marine_document, :product_catalog, assistant: assistant, product_family_code: 'FAM-100')
      other = build(:marine_document, :product_catalog, assistant: other_assistant, product_family_code: 'FAM-100')

      expect(other).to be_valid
    end
  end

  describe 'response builder callback isolation' do
    it 'does not enqueue the response builder job for product catalogs' do
      expect(Marine::Documents::ResponseBuilderJob).not_to receive(:perform_later)
      create(:marine_document, :product_catalog)
    end

    it 'enqueues the response builder job for website documents with content' do
      expect(Marine::Documents::ResponseBuilderJob).to receive(:perform_later)
      create(:marine_document, :website, content: 'website knowledge body')
    end
  end

  describe 'existing website behavior' do
    let(:assistant) { create(:marine_assistant) }

    it 'validates external_link uniqueness scoped to the assistant' do
      create(:marine_document, :website, assistant: assistant, external_link: 'https://example.com/docs')
      duplicate = build(:marine_document, :website, assistant: assistant, external_link: 'https://example.com/docs')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:external_link]).to be_present
    end

    it 'allows the same external_link for a different assistant' do
      other_assistant = create(:marine_assistant)
      create(:marine_document, :website, assistant: assistant, external_link: 'https://example.com/docs')
      other = build(:marine_document, :website, assistant: other_assistant, external_link: 'https://example.com/docs')

      expect(other).to be_valid
    end

    it 'normalizes a trailing slash on the external_link' do
      document = create(:marine_document, :website, external_link: 'https://example.com/docs/')
      expect(document.external_link).to eq('https://example.com/docs')
    end

    it 'derives account_id from the assistant' do
      document = create(:marine_document, :website)
      expect(document.account_id).to eq(document.assistant.account_id)
    end
  end
end
