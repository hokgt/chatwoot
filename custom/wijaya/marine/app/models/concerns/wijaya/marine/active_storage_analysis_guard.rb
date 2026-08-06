# Narrowly-scoped guard prepended to ActiveStorage::Attachment.
#
# WHY: Rails 7.1 unconditionally schedules analysis for image/PDF attachments via an
# `after_create_commit :analyze_blob_later` callback; passing `identify: false` to the
# blob does NOT prevent that ActiveStorage::AnalyzeJob from being enqueued. Marine
# Product Catalog blobs must be stored as the exact validated bytes with no analyzer /
# preview work, so the ProductCatalogService marks those blobs with persistent metadata
# `wijaya_skip_analysis => true`.
#
# This module overrides `analyze_blob_later` and returns early ONLY for a marked blob;
# every other attachment falls through to `super`, so ordinary Chatwoot attachments keep
# their normal analysis behavior untouched. The module is prepended idempotently from the
# Marine loader's to_prepare hook.
module Wijaya
  module Marine
    module ActiveStorageAnalysisGuard
      SKIP_METADATA_KEY = 'wijaya_skip_analysis'.freeze

      private

      def analyze_blob_later
        return if blob&.metadata&.[](SKIP_METADATA_KEY)

        super
      end
    end
  end
end
