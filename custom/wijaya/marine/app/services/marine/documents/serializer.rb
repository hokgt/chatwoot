# Source-aware JSON serialization for Marine documents. Preserves the existing
# document attributes exactly (source_kind, product_family_code, and primary_catalog
# are already real columns returned by as_json) and ADDITIVELY exposes a `source_file`
# block with file METADATA ONLY for file-backed sources. Website documents serialize
# with `source_file: nil`, so existing website behavior is preserved (no field is
# removed).
#
# NO download/URL is emitted in Commit 1B. A Rails signed blob path is not an
# account-scoped authorization endpoint, so no public or signed URL is exposed here;
# a download link will only appear once a separately authorized download endpoint
# exists. Accessing blob.filename/content_type/byte_size/checksum does NOT trigger any
# ActiveStorage analyzer/preview work.
module Marine
  module Documents
    module Serializer
      module_function

      def call(document)
        json = document.as_json.merge('source_file' => file_metadata(document))
        # SOP extracted text is internal knowledge-base content, never returned by the
        # documents API. The `content` key is preserved (stable shape) but always nil for
        # sop_document. Website/product_catalog serialization is unchanged.
        json['content'] = nil if document.sop_document?
        json
      end

      def file_metadata(document)
        return nil unless document.source_file.attached?

        blob = document.source_file.blob
        {
          'filename' => blob.filename.to_s,
          'content_type' => blob.content_type,
          'byte_size' => blob.byte_size,
          'checksum' => blob.checksum
        }
      end
    end
  end
end
