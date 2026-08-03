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
    end
  end
end
