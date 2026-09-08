# Source-aware JSON serialization for Marine documents. Confidentiality is enforced by
# construction: internal content, arbitrary metadata, checksums, storage keys, and URLs
# never reach API clients. Only explicitly allowlisted UI status values and safe file
# metadata are emitted.
module Marine
  module Documents
    module Serializer
      module_function

      SAFE_INDEXING_STATUSES = %w[pending embedding_pending indexed failed].freeze
      SAFE_LAST_SYNC_ERROR_CODES = %w[
        website_no_readable_content
        website_sync_failed
        sop_enqueue_failed
        sop_page_limit_exceeded
        sop_pdf_invalid
        sop_extraction_failed
        sop_ocr_failed
        sop_image_invalid
        sop_ocr_timeout
        sop_no_readable_text
        sop_processing_dependency_unavailable
      ].freeze
      SAFE_INDEXING_ERROR_CODES = %w[sop_index_failed sop_index_enqueue_failed].freeze

      def call(document)
        json = document.as_json
        json.delete('content')
        json['metadata'] = safe_metadata(document)
        json['source_file'] = file_metadata(document)
        json
      end

      def safe_metadata(document)
        metadata = document.metadata
        return {} unless metadata.is_a?(Hash)

        {}.tap do |safe|
          status = metadata['indexing_status']
          safe['indexing_status'] = status if SAFE_INDEXING_STATUSES.include?(status)

          count = metadata['indexed_chunk_count']
          safe['indexed_chunk_count'] = count if count.is_a?(Integer) && count >= 0

          sync_error = metadata['last_sync_error_code']
          safe['last_sync_error_code'] = sync_error if SAFE_LAST_SYNC_ERROR_CODES.include?(sync_error)

          index_error = metadata['indexing_error_code']
          safe['indexing_error_code'] = index_error if SAFE_INDEXING_ERROR_CODES.include?(index_error)
        end
      end

      def file_metadata(document)
        return nil unless document.source_file.attached?

        blob = document.source_file.blob
        {
          'filename' => blob.filename.to_s,
          'content_type' => blob.content_type,
          'byte_size' => blob.byte_size
        }
      end
    end
  end
end
