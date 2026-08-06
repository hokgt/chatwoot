# Creates or explicitly replaces the single primary Product Catalog document for a
# Marine assistant + product family. This is the ONLY write path for product_catalog
# documents in Commit 1B.
#
# Guarantees:
#   * account scoping — the assistant must belong to the given account,
#   * the upload passes UploadValidator (type/extension/signature/size/empty),
#   * the product family exists in the canonical Marine item data,
#   * exactly one attached file, source_kind=product_catalog, primary_catalog=true,
#     and NO url/content — enforced by the model + the Commit 1A partial unique index,
#   * at most one primary catalog per assistant+family (row lock + partial index),
#   * a replacement is EXPLICIT (replace: true); otherwise a duplicate is a
#     deterministic PrimaryConflictError,
#   * the exact original bytes are stored via ActiveStorage with no analyzer/preview
#     work — the blob is marked with persistent `wijaya_skip_analysis` metadata so the
#     Wijaya ActiveStorageAnalysisGuard suppresses ActiveStorage::AnalyzeJob (identify:
#     false alone does NOT), preserving filename, validated MIME, size, and checksum,
#   * on success the OLD blob is purged best-effort only AFTER the DB replacement
#     commits; a purge failure is logged (class/tag only) and never turns a committed
#     replacement into a 500,
#   * on ANY failure the newly-created blob/file is cleaned up and the old primary /
#     file is preserved (the whole DB change is inside one transaction).
#
# It never enqueues the website response builder or any sync/analysis job.
module Marine
  module Documents
    class ProductCatalogService
      def initialize(account:, assistant:, product_family_code:, upload:,
                     primary_catalog: true, replace: false, name: nil,
                     repository: Marine::Catalog::ProductFamilyRepository.new)
        @account = account
        @assistant = assistant
        @product_family_code = product_family_code.to_s.strip
        @upload = upload
        @primary_catalog = primary_catalog
        @replace = ActiveModel::Type::Boolean.new.cast(replace) || false
        @name = name
        @repository = repository
      end

      def call
        ensure_account_scope!
        ensure_primary_intent!
        validated = UploadValidator.new(@upload).call
        ensure_family_exists!
        persist(validated)
      end

      private

      def ensure_account_scope!
        return if @assistant.present? && @assistant.account_id == @account&.id

        raise Errors::AccountMismatchError
      end

      # Product catalogs are always primary in the approved model; a non-primary
      # intent is rejected deterministically rather than silently coerced.
      def ensure_primary_intent!
        return unless ActiveModel::Type::Boolean.new.cast(@primary_catalog) == false

        raise Errors::InvalidFileError.new('A product catalog must be primary')
      end

      def ensure_family_exists!
        return if @repository.exists?(@product_family_code)

        raise Errors::UnknownFamilyError
      end

      def persist(validated)
        # Fail fast on an obvious conflict before uploading any bytes.
        raise Errors::PrimaryConflictError if !@replace && existing_primary_scope.exists?

        blob = create_blob(validated)
        document = nil
        old_blob = nil

        begin
          Marine::Document.transaction do
            existing = existing_primary_scope.lock.first
            raise Errors::PrimaryConflictError if existing && !@replace

            document = build_document
            document.source_file.attach(blob)

            if existing
              # Detach (not purge) so the old file survives a rollback; purge only
              # after the whole replacement commits.
              old_blob = existing.source_file.blob
              existing.source_file.detach
              existing.destroy!
            end

            document.save!
          end
        rescue ActiveRecord::RecordNotUnique
          blob.purge
          raise Errors::PrimaryConflictError
        rescue StandardError
          blob.purge
          raise
        end

        purge_old_blob(old_blob)
        document
      end

      # The DB replacement has already committed successfully, so a failure to purge
      # the superseded blob must NOT fail the request. Purge best-effort and swallow the
      # error after logging only its class/tag — never the message (which for storage
      # backends can echo paths/keys) — returning the committed new document.
      def purge_old_blob(old_blob)
        return if old_blob.nil?

        old_blob.purge
      rescue StandardError => e
        Rails.logger.error({ tag: 'marine.catalog.old_blob_purge_failed', error_class: e.class.name }.to_json)
      end

      def existing_primary_scope
        @assistant.documents.where(
          source_kind: 'product_catalog',
          product_family_code: @product_family_code,
          primary_catalog: true
        )
      end

      # Uploads the exact original bytes and creates the blob in its own committed
      # transaction (outside the document transaction) so we can deterministically
      # purge it on failure. identify: false skips MIME re-identification; the persistent
      # wijaya_skip_analysis metadata is what stops ActiveStorage::AnalyzeJob (via the
      # Wijaya ActiveStorageAnalysisGuard prepended to ActiveStorage::Attachment).
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

      def build_document
        @assistant.documents.new(
          account: @account,
          source_kind: 'product_catalog',
          product_family_code: @product_family_code,
          primary_catalog: true,
          name: document_name,
          status: :available
        )
      end

      def document_name
        @name.presence || original_filename.presence || "Catalog #{@product_family_code}"
      end

      def original_filename
        @upload.respond_to?(:original_filename) ? @upload.original_filename.to_s : ''
      end
    end
  end
end
