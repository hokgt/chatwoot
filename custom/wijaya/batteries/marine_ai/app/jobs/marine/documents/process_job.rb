# Asynchronous SOP extraction/OCR job (Commit 1C).
#
# For a sop_document it: marks the document syncing, extracts+normalizes the EXACT
# stored original via the SOP extraction pipeline, and ATOMICALLY saves the extracted
# content plus sanitized metadata (processing_method, page_count, content_fingerprint)
# and the synced/available state. It is idempotent and safe to re-run (reprocess), and
# a stale/concurrent run can never overwrite a newer file's result.
#
# After guarded extraction succeeds it enqueues the Commit 1D ResponseBuilderJob with
# the exact content fingerprint; indexing remains isolated from OCR and stale-run safe. For a
# product_catalog it is a strict safe no-op (catalogs are never extracted). Website
# documents are not routed here; their sync path is unchanged.
require 'digest'
require 'securerandom'

module Marine
  module Documents
    class ProcessJob < ApplicationJob
      # Runs on a DEDICATED marine_sop queue (not shared :low) so SOP extraction/OCR is
      # only ever picked up by the isolated, resource-capped marine_sop_worker service.
      # The main sidekiq config never lists marine_sop, so normal workers never run it.
      queue_as :marine_sop

      # expected_blob_id and run_token are OPTIONAL so jobs already queued before this
      # change (serialized with only the document) still run: a legacy invocation simply
      # claims the currently-attached blob and mints its own run token.
      def perform(document, expected_blob_id = nil, run_token = nil)
        return unless document.sop_document?
        return unless document.source_file.attached?

        claim = claim_run(document, expected_blob_id, run_token)
        return unless claim

        blob_id, token = claim
        process(document, blob_id, token)
      end

      private

      # Atomically claims this run under a row lock: only if the still-attached blob
      # matches the one the enqueuer expected (when supplied) do we mark the document
      # syncing and stamp our run token. Returns [blob_id, token] on a successful claim,
      # or nil when a newer upload already superseded the expected blob (no-op).
      def claim_run(document, expected_blob_id, run_token)
        Marine::Document.transaction do
          locked = Marine::Document.lock.find(document.id)
          next nil unless locked.source_file.attached?

          current_blob_id = locked.source_file.blob.id
          next nil if expected_blob_id.present? && expected_blob_id != current_blob_id

          token = run_token.presence || SecureRandom.uuid
          locked.update!(sync_status: :syncing, last_sync_attempted_at: Time.current, sync_run_token: token)
          [current_blob_id, token]
        end
      end

      def process(document, blob_id, token)
        result = Sop::ExtractionService.new(blob: document.source_file.blob).call
        save_success(document, result, blob_id, token)
      rescue Marine::Documents::Errors::SopProcessingError => e
        mark_failed(document, e.error_code, blob_id, token)
      rescue StandardError => e
        # Any unexpected failure from download/extraction/tool orchestration is
        # collapsed to a stable code; we log ONLY a structured tag + error_class so
        # Sidekiq can never persist a raw message, backtrace, path, argv or content.
        Rails.logger.error({ tag: 'marine.sop.process_error', error_class: e.class.name }.to_json)
        mark_failed(document, 'sop_extraction_failed', blob_id, token)
      end

      # Atomic success write, guarded by blob id + run token. Commit 1D indexing is queued
      # only after this transaction commits, with the exact persisted fingerprint. A stale
      # run therefore cannot enqueue an index replacement for newer extracted content.
      def save_success(document, result, blob_id, token)
        fingerprint = Digest::SHA256.hexdigest(result.content)

        persisted = Marine::Document.transaction do
          locked = Marine::Document.lock.find(document.id)
          next false unless owns_run?(locked, blob_id, token)

          locked.update!(success_attributes(result, fingerprint))
          true
        end
        enqueue_indexing(document, fingerprint) if persisted
      end

      def success_attributes(result, fingerprint)
        {
          content: result.content, status: :available, sync_status: :synced,
          last_synced_at: Time.current, last_sync_error_code: nil,
          processing_method: result.processing_method, page_count: result.page_count,
          content_fingerprint: fingerprint, sync_run_token: nil,
          indexing_status: 'pending', indexing_error_code: nil
        }
      end

      # Broker failure never downgrades extracted synced/available content. Persist only a
      # stable index error guarded by the same fingerprint and log only the exception class.
      def enqueue_indexing(document, fingerprint)
        Marine::Documents::ResponseBuilderJob.perform_later(document, fingerprint)
      rescue StandardError => e
        Rails.logger.error({ tag: 'marine.sop.index_enqueue_error', error_class: e.class.name }.to_json)
        mark_index_enqueue_failed(document, fingerprint)
      end

      def mark_index_enqueue_failed(document, fingerprint)
        Marine::Document.transaction do
          locked = Marine::Document.lock.find_by(id: document.id)
          next unless locked&.sop_document? && locked.sync_synced?
          next unless locked.content_fingerprint == fingerprint

          locked.update!(indexing_status: 'failed', indexing_error_code: 'sop_index_enqueue_failed')
        end
      rescue StandardError => e
        Rails.logger.error({ tag: 'marine.sop.index_enqueue_failed_persist', error_class: e.class.name }.to_json)
      end

      # Records only the stable sanitized error code, guarded by BOTH blob id and run
      # token exactly like the success path: a stale/superseded run no-ops. If a prior
      # successful run already produced good content for this same file, a later
      # duplicate/concurrent FAILURE must NOT downgrade it — we preserve the last good
      # synced/available content and simply release the run claim.
      def mark_failed(document, error_code, blob_id, token)
        Marine::Document.transaction do
          locked = Marine::Document.lock.find(document.id)
          # Not our run: commit the (empty) transaction and stop — a stale/superseded failure must not write.
          next unless owns_run?(locked, blob_id, token)

          if locked.content.present?
            locked.update!(status: :available, sync_status: :synced, last_sync_error_code: nil, sync_run_token: nil)
          else
            locked.update!(
              sync_status: :failed,
              last_sync_attempted_at: Time.current,
              last_sync_error_code: error_code,
              sync_run_token: nil
            )
          end
        end
      rescue StandardError => e
        Rails.logger.error({ tag: 'marine.sop.process_failed_persist', error_class: e.class.name }.to_json)
      end

      # A transition is applied only when the locked row STILL carries the exact blob we
      # processed AND the exact run token we claimed. Either mismatch means a newer upload
      # or a newer run superseded us.
      def owns_run?(locked, blob_id, token)
        current_blob_id = locked.source_file.attached? ? locked.source_file.blob.id : nil
        current_blob_id == blob_id && locked.sync_run_token == token
      end
    end
  end
end
