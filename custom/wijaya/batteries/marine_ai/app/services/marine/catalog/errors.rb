# Sanitized errors for the read-only Marine product catalog (canonical item data)
# access path. The API must never see raw PG errors, connection strings, SQL text,
# or secrets — the repository fails closed with CatalogUnavailableError, which the
# controller maps to a 503.
module Marine
  module Catalog
    module Errors
      class CatalogError < StandardError
        attr_reader :i18n_key

        def initialize(message = 'The product catalog could not be reached', i18n_key: 'MARINE.DOCUMENTS.ERRORS.CATALOG_UNAVAILABLE')
          @i18n_key = i18n_key
          super(message)
        end
      end

      # Raised when the catalog database is unconfigured, unreachable, times out, or
      # otherwise fails. Fail closed; never expose the underlying reason. -> 503
      class CatalogUnavailableError < CatalogError; end
    end
  end
end
