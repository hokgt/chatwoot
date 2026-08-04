# Source-aware JSON serialization for Marine documents. Confidentiality is enforced by
# construction: instead of echoing the whole record, this serializer starts from the
# document attributes and then strips/replaces everything that must never reach an API
# client. The document's own columns (source_kind, product_family_code, primary_catalog,
# sync_status, status, timestamps, etc.) are preserved so existing website/product-catalog
# and SOP UI behavior is unchanged.
#
# NEVER exposed to clients:
#   * `content` — scraped/extracted knowledge-base body (key removed entirely),
#   * the raw `metadata` store — replaced by an explicit safe allowlist, so backend
#     internals (content_fingerprint, indexed_fingerprint, the internal sync_run_token,
#     extraction step/method/page internals, original blob details) stay server-side,
#     even if new internal metadata keys are added later,
#   * `source_file.checksum` — a content-addressable digest of the stored bytes,
#   * any download/signed URL or ActiveStorage storage key.
#
# Only file METADATA (filename/content_type/byte_size) is emitted for file-backed sources.
# Website documents serialize with `source_file: nil`. Accessing blob.filename/
# content_type/byte_size does NOT trigger any ActiveStorage analyzer/preview work.
module Marine
  module Documents
    module Serializer
      module_function

      # The ONLY metadata keys safe to send to API clients. Everything else in the
      # document's metadata store is internal and must stay on the backend.
      SAFE_METADATA_KEYS = %w[
        indexing_status
        indexed_chunk_count
        last_sync_error_code
        indexing_error_code
      ].freeze

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

        metadata.slice(*SAFE_METADATA_KEYS)
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
