# frozen_string_literal: true

require 'rails_helper'

# Confidentiality regression for the client-facing Marine document serializer. Backend
# internals live in the model's metadata store but must NEVER be serialized to an API
# client. These are pure serializer assertions (no HTTP) so a leak fails fast and loud.
RSpec.describe Marine::Documents::Serializer do
  let(:account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }

  # Every metadata/attribute key that must stay server-side.
  let(:forbidden_keys) do
    %w[
      content_fingerprint indexed_fingerprint sync_run_token sync_step
      processing_method page_count original_filename detected_content_type
      original_byte_size indexed_at
    ]
  end

  describe '.call for an SOP document' do
    subject(:json) { described_class.call(document) }

    let(:document) do
      doc = create(:marine_document, :sop_document, assistant: assistant)
      doc.update!(
        content: 'CONFIDENTIAL extracted SOP body',
        sync_status: :synced,
        metadata: {
          'content_fingerprint' => 'fp-content-abc',
          'indexed_fingerprint' => 'fp-index-def',
          'sync_run_token' => 'secret-run-token',
          'sync_step' => 'embedding',
          'processing_method' => 'ocr',
          'page_count' => 12,
          'original_filename' => 'procedure.pdf',
          'detected_content_type' => 'application/pdf',
          'original_byte_size' => 4096,
          'indexing_status' => 'indexed',
          'indexed_chunk_count' => 7,
          'last_sync_error_code' => nil,
          'indexing_error_code' => nil
        }
      )
      doc
    end

    it 'never serializes the extracted content' do
      expect(json).not_to have_key('content')
      expect(json.to_json).not_to include('CONFIDENTIAL')
    end

    it 'never serializes the source_file checksum, download URL, or storage key' do
      expect(json['source_file'].keys).to match_array(%w[filename content_type byte_size])
      expect(json['source_file']).not_to have_key('checksum')
      expect(json['source_file']).not_to have_key('download_url')
      expect(json['source_file']).not_to have_key('key')
    end

    it 'exposes ONLY the safe metadata allowlist and drops every internal key' do
      expect(json['metadata'].keys).to match_array(%w[indexing_status indexed_chunk_count])
      forbidden_keys.each do |key|
        expect(json['metadata']).not_to have_key(key), "expected metadata not to expose #{key}"
        expect(json.to_json).not_to include(key)
      end
    end

    it 'still exposes the safe UI status fields' do
      expect(json['metadata']['indexing_status']).to eq('indexed')
      expect(json['metadata']['indexed_chunk_count']).to eq(7)
      expect(json['sync_status']).to eq('synced')
    end
  end

  describe '.call for a website document' do
    let(:document) { create(:marine_document, :website, assistant: assistant) }

    it 'serializes source_file as nil and omits content' do
      json = described_class.call(document)
      expect(json['source_file']).to be_nil
      expect(json).not_to have_key('content')
      expect(json['source_kind']).to eq('website')
    end

    it 'suppresses arbitrary legacy sync errors but permits known stable codes' do
      document.update!(last_sync_error_code: 'connection failed for http://internal.example/secret')
      json = described_class.call(document)
      expect(json['metadata']).not_to have_key('last_sync_error_code')
      expect(json.to_json).not_to include('internal.example')

      document.update!(last_sync_error_code: 'website_sync_failed')
      expect(described_class.call(document).dig('metadata', 'last_sync_error_code')).to eq('website_sync_failed')
    end
  end
end
