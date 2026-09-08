# Phase 6 — Deterministic selection of the single usable primary Product Catalog
# document for a Marine assistant + validated product family. It is READ-ONLY: it never
# creates, uploads, converts, parses, or mutates a document or blob, and it infers
# nothing from a filename. Selection is exact and fail-closed — it returns the one
# `available`, `primary_catalog`, file-backed `product_catalog` document scoped to the
# account + assistant + exact validated family, or nil when the family is blank, no such
# document exists, or the single match has no attached source_file (unusable). The
# partial unique index on (assistant_id, product_family_code) for primary product
# catalogs guarantees at most one candidate, so this never returns an arbitrary row.
module Marine
  module Documents
    class ProductCatalogSelector
      def initialize(account:, assistant:, family_code:)
        @account = account
        @assistant = assistant
        @family_code = family_code.to_s.strip
      end

      def call
        return nil if @account.nil? || @assistant.nil? || @family_code.empty?

        document = scope.first
        return nil if document.nil?
        return nil unless document.source_file.attached?

        document
      end

      private

      def scope
        @assistant.documents.available.where(
          account_id: @account.id,
          source_kind: 'product_catalog',
          primary_catalog: true,
          product_family_code: @family_code
        )
      end
    end
  end
end
