# Asynchronous SOP extraction/OCR job (Commit 1C).
#
# For a sop_document it: marks the document syncing, extracts+normalizes the EXACT
# stored original via the SOP extraction pipeline, and ATOMICALLY saves the extracted
# content plus sanitized metadata (processing_method, page_count, content_fingerprint)
# and the synced/available state. It is idempotent and safe to re-run (reprocess), and
# a stale/concurrent run can never overwrite a newer file's result.
#
# It NEVER creates Marine::AssistantResponse, chunks, embeddings, or citations, and
# never calls ResponseBuilderJob — that indexing pipeline is Commit 1D. For a
# product_catalog it is a strict safe no-op (catalogs are never extracted). Website
# documents are not routed here; their sync path is unchanged.
require 'digest'

module Marine
  module Documents
    class ProcessJob < ApplicationJob
      queue_as :low

      def perform(document)
        return unless document.sop_document?
        return unless document.source_file.attached?

        process(document)
      end

      private

      def process(document)
        source_blob_id = document.source_file.blob.id
        mark_syncing(document)

        result = Sop::ExtractionService.new(blob: document.source_file.blob).call
        save_success(document, result, source_blob_id)
      rescue Marine::Documents::Errors::SopProcessingError => e
        mark_failed(document, e.error_code, source_blob_id)
      rescue StandardError => e
        # Any unexpected failure from download/extraction/tool orchestration is
        # collapsed to a stable code; we log ONLY a structured tag + error_class so
        # Sidekiq can never persist a raw message, backtrace, path, argv or content.
        Rails.logger.error({ tag: 'marine.sop.process_error', error_class: e.class.name }.to_json)
        mark_failed(document, 'sop_extraction_failed', source_blob_id)
      end

      def mark_syncing(document)
        document.update!(sync_status: :syncing, last_sync_attempted_at: Time.current)
      end

      # Atomic success write, guarded against stale/concurrent runs: under a row lock we
      # re-check that the still-attached blob matches the one we actually extracted; if a
      # newer file has replaced it, this older run yields to the newer one. Idempotent —
      # a re-run that produces the same fingerprint on an already-synced document is a
      # no-op. Only content/metadata/state change; the original file is untouched.
      def save_success(document, result, source_blob_id)
        fingerprint = Digest::SHA256.hexdigest(result.content)

        Marine::Document.transaction do
          locked = Marine::Document.lock.find(document.id)
          current_blob_id = locked.source_file.attached? ? locked.source_file.blob.id : nil
          return if current_blob_id != source_blob_id
          return if locked.sync_synced? && locked.content_fingerprint == fingerprint

          locked.assign_attributes(
            content: result.content,
            status: :available,
            sync_status: :synced,
            last_synced_at: Time.current,
            last_sync_error_code: nil,
            processing_method: result.processing_method,
            page_count: result.page_count,
            content_fingerprint: fingerprint
          )
          locked.save!
        end
      end

      # Keeps the original file and any prior extracted content; records only the stable
      # sanitized error code. Guarded against stale/concurrent runs exactly like the
      # success path: under a row lock we re-check that the still-attached blob matches
      # the one this run actually processed. If a newer file has replaced it, an older
      # failed run must NOT mark the document failed and clobber the newer run — it
      # no-ops.
      def mark_failed(document, error_code, source_blob_id)
        Marine::Document.transaction do
          locked = Marine::Document.lock.find(document.id)
          current_blob_id = locked.source_file.attached? ? locked.source_file.blob.id : nil
          return if current_blob_id != source_blob_id

          locked.update!(
            sync_status: :failed,
            last_sync_attempted_at: Time.current,
            last_sync_error_code: error_code
          )
        end
      rescue StandardError => e
        Rails.logger.error({ tag: 'marine.sop.process_failed_persist', error_class: e.class.name }.to_json)
      end
    end
  end
end
