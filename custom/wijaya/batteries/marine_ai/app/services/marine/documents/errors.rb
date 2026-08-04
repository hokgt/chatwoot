# Stable, sanitized error hierarchy for Marine Product Catalog management. Every
# error surfaced to the API maps to a deterministic HTTP status in the controller
# and carries only a safe human message plus an i18n key — never a filesystem path,
# raw file content, SQL, or catalog internals.
module Marine
  module Documents
    module Errors
      class ServiceError < StandardError
        attr_reader :i18n_key

        def initialize(message = 'The request could not be completed', i18n_key: 'MARINE.DOCUMENTS.ERRORS.GENERIC')
          @i18n_key = i18n_key
          super(message)
        end
      end

      # The uploaded file failed validation (type/extension/signature mismatch,
      # empty, oversized, malformed, or unsupported). -> 422
      class InvalidFileError < ServiceError
        def initialize(message = 'The uploaded file is invalid', i18n_key: 'MARINE.DOCUMENTS.ERRORS.INVALID_FILE')
          super
        end
      end

      # The supplied product family code does not exist in the canonical Marine
      # item data. -> 422
      class UnknownFamilyError < ServiceError
        def initialize(message = 'The product family is unknown', i18n_key: 'MARINE.DOCUMENTS.ERRORS.UNKNOWN_FAMILY')
          super
        end
      end

      # A primary catalog already exists for this assistant + family and the request
      # did not explicitly ask to replace it. -> 409
      class PrimaryConflictError < ServiceError
        def initialize(message = 'A primary catalog already exists for this product family', i18n_key: 'MARINE.DOCUMENTS.ERRORS.PRIMARY_CONFLICT')
          super
        end
      end

      # The Marine assistant does not belong to the current account. -> 403
      class AccountMismatchError < ServiceError
        def initialize(message = 'The assistant does not belong to this account', i18n_key: 'MARINE.DOCUMENTS.ERRORS.ACCOUNT_MISMATCH')
          super
        end
      end

      # The document's source kind cannot be synced/reprocessed (e.g. a product
      # catalog, which is never OCRed/extracted). -> 422
      class NotSyncableError < ServiceError
        def initialize(message = 'This document type cannot be synced', i18n_key: 'MARINE.DOCUMENTS.ERRORS.NOT_SYNCABLE')
          super
        end
      end

      # Queuing the asynchronous SOP reprocessing job failed (e.g. the job broker is
      # unavailable). The document has already been rolled back to a stable failed
      # state; the client gets a sanitized, deterministic error. -> 503
      class EnqueueFailedError < ServiceError
        def initialize(message = 'The document could not be queued for processing', i18n_key: 'MARINE.DOCUMENTS.ERRORS.ENQUEUE_FAILED')
          super
        end
      end

      # Internal, sanitized SOP extraction/OCR failures. These are NEVER surfaced to
      # the API (SOP processing is asynchronous); they are caught by the SOP processing
      # job and persisted ONLY as a stable `last_sync_error_code`. They deliberately do
      # NOT inherit from ServiceError so they can never be caught by the controller's
      # `rescue_from ServiceError` and leak. The message is a fixed, safe, generic
      # sentence — never a path, command line, raw stderr, or file content.
      class SopProcessingError < StandardError
        attr_reader :error_code

        def initialize(error_code)
          @error_code = error_code
          super('The document could not be processed')
        end
      end

      class SopPageLimitExceededError < SopProcessingError
        def initialize = super('sop_page_limit_exceeded')
      end

      class SopPdfInvalidError < SopProcessingError
        def initialize = super('sop_pdf_invalid')
      end

      class SopExtractionFailedError < SopProcessingError
        def initialize = super('sop_extraction_failed')
      end

      class SopOcrFailedError < SopProcessingError
        def initialize = super('sop_ocr_failed')
      end

      # A directly-uploaded image whose decoded dimensions are missing, zero, malformed,
      # or exceed the conservative SOP page bounds (a decompression-bomb guard). -> code only
      class SopImageInvalidError < SopProcessingError
        def initialize = super('sop_image_invalid')
      end

      class SopOcrTimeoutError < SopProcessingError
        def initialize = super('sop_ocr_timeout')
      end

      class SopNoReadableTextError < SopProcessingError
        def initialize = super('sop_no_readable_text')
      end

      class SopProcessingDependencyUnavailableError < SopProcessingError
        def initialize = super('sop_processing_dependency_unavailable')
      end
    end
  end
end
