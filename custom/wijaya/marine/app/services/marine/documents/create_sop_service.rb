# Creates a single SOP document for a Marine assistant and queues asynchronous
# extraction (Commit 1C). This is the ONLY write path for sop_document sources.
#
# Guarantees:
#   * account scoping — the assistant must belong to the given account,
#   * the upload passes the SAME strict Commit 1B UploadValidator
#     (type/extension/signature/size/empty),
#   * the EXACT original bytes are stored via ActiveStorage with NO analyzer/preview
#     work (persistent wijaya_skip_analysis metadata), preserving filename, validated
#     MIME, size, and checksum,
#   * the document is created source_kind=sop_document, external_link=nil,
#     product_family_code=nil, primary_catalog=false, status=in_progress,
#     sync_status=syncing, content=nil,
#   * the processing job is enqueued ONLY AFTER the DB transaction commits; if enqueue
#     fails the original file is retained and sync_status is marked failed with a stable
#     sanitized error code,
#   * on ANY persistence failure the newly-created orphan blob/file is purged.
#
# It never sets or accepts client-controlled status/sync/processing/blob metadata, and
# never creates AssistantResponse/chunks/embeddings (that is Commit 1D).
module Marine
  module Documents
    class CreateSopService
      MAX_FILENAME_LENGTH = 255
      MAX_NAME_LENGTH = 255

      def initialize(account:, assistant:, upload:, name: nil)
        @account = account
        @assistant = assistant
        @upload = upload
        @name = name
      end

      def call
        ensure_account_scope!
        validated = UploadValidator.new(@upload).call
        document = persist(validated)
        enqueue_processing(document)
        document
      end

      private

      def ensure_account_scope!
        return if @assistant.present? && @assistant.account_id == @account&.id

        raise Errors::AccountMismatchError
      end

      def persist(validated)
        blob = create_blob(validated)
        document = nil
        begin
          Marine::Document.transaction do
            document = build_document(validated)
            document.source_file.attach(blob)
            document.save!
          end
        rescue StandardError
          purge_orphan(blob)
          raise
        end
        document
      end

      # Best-effort purge of the just-created orphan blob. It must NEVER mask the original
      # persistence exception (that is re-raised by the caller) and, if the purge itself
      # fails, logs only a stable tag + error_class — never a path, key, or raw message.
      def purge_orphan(blob)
        blob.purge
      rescue StandardError => e
        Rails.logger.error({ tag: 'marine.sop.orphan_purge_failed', error_class: e.class.name }.to_json)
      end

      # Uploads the exact original bytes with analysis suppressed, exactly like the
      # Commit 1B product-catalog path.
      def create_blob(validated)
        @upload.rewind if @upload.respond_to?(:rewind)
        ActiveStorage::Blob.create_and_upload!(
          io: @upload,
          filename: validated.filename,
          content_type: validated.content_type,
          identify: false,
          metadata: { Wijaya::Marine::ActiveStorageAnalysisGuard::SKIP_METADATA_KEY => true }
        )
      end

      def build_document(validated)
        @assistant.documents.new(
          account: @account,
          source_kind: 'sop_document',
          name: document_name(validated),
          status: :in_progress,
          sync_status: :syncing,
          content: nil,
          last_sync_attempted_at: Time.current,
          metadata: {
            'original_filename' => sanitized_filename(validated.filename),
            'detected_content_type' => validated.content_type,
            'original_byte_size' => validated.byte_size
          }
        )
      end

      # After-commit enqueue. A broker failure must NOT lose the uploaded file: the
      # document is marked failed with a stable code and the original bytes are retained.
      def enqueue_processing(document)
        Marine::Documents::ProcessJob.perform_later(document)
      rescue StandardError
        document.update!(
          sync_status: :failed,
          last_sync_attempted_at: Time.current,
          last_sync_error_code: 'sop_enqueue_failed'
        )
      end

      def document_name(validated)
        sanitized_client_name.presence || sanitized_filename(validated.filename).presence || 'SOP Document'
      end

      # A client-supplied name is control-stripped, trimmed, and truncated to a safe max
      # so it can never carry control characters or unbounded length into the record.
      def sanitized_client_name
        return nil if @name.nil?

        @name.to_s.gsub(/[[:cntrl:]]/, '').strip[0, MAX_NAME_LENGTH]
      end

      # Strips any directory component and unsafe characters; never a path.
      def sanitized_filename(filename)
        base = File.basename(filename.to_s)
        base = base.gsub(/[[:cntrl:]]/, '').strip
        base[0, MAX_FILENAME_LENGTH]
      end
    end
  end
end
