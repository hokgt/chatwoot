# Phase 3 — read-only repository for a BOUNDED, deterministic catalog LISTING of active
# TOP-LEVEL products over the canonical Marine item data (schema-qualified `marine_ai.item`).
#
# "Top-level" = a product the customer can be shown as a catalog entry: an active TEMPLATE
# (has_variants = true) OR an active STANDALONE product (has_variants = false). What makes a row
# top-level is that it is NOT a child/variant: a variant row carries its parent family code in
# `variant_of`, so the canonical top-level test is "variant_of is empty". A plain `variant_of IS
# NULL` is WRONG — it silently drops a standalone row whose `variant_of` is a blank/whitespace
# string (equally not a child), so the catalog-authoritative predicate is
# `disabled = false AND COALESCE(BTRIM(variant_of), '') = ''`: a disabled row is excluded, a NULL
# or blank/whitespace `variant_of` is kept, and only a row naming an actual parent family is
# dropped. `has_variants` is deliberately NOT in the predicate: it merely splits template vs
# standalone, and both are top-level — it does not discriminate top-level-ness, so adding it would
# only risk dropping a legitimately listable row on a dirty flag. Deterministically ordered by
# item_code.
#
# The listing is a BOUNDED PAGE with EXACT completeness metadata, never an exhaustive dump and
# never a silent truncation:
#   * a single SELECT fetches page_limit + 1 rows, so `has_more` (and thus `complete`) is known
#     exactly from whether an extra row came back;
#   * `returned_count` is the size of the capped page actually returned;
#   * `total_count` is the page size itself when complete (no extra query), or a safe COUNT(*)
#     when there is more — and nil if that count cannot be obtained safely (the caller stays
#     honest about a bounded selection rather than claiming a total it does not have).
# `limit` is clamped to [1, MAX_PAGE]; MAX_PAGE is the hard repository ceiling. Everything is
# parameterized, SELECT-only, and fails closed with CatalogUnavailableError when the catalog DB
# is unconfigured/unreachable. No UI, no provider, no state is built here.
module Marine
  module Catalog
    class ProductListingRepository
      # Conservative page cap aligned with the existing catalog DEFAULT_LIMIT, chosen so the bounded
      # page fits the 16 KiB Evidence packet and a useful customer reply. It is also the hard ceiling.
      MAX_PAGE = 20
      DEFAULT_PAGE = 20

      # Bounded, deterministic listing of ACTIVE TOP-LEVEL products. Returns:
      #   { products: [{ code:, name: }], returned_count:, total_count: (Integer|nil), complete: }
      # complete == true means the returned page IS the whole active top-level set.
      def active_top_level(limit: DEFAULT_PAGE)
        ensure_configured!
        capped = clamp_limit(limit)
        probe = Marine::Catalog::Connection.select(listing_sql, [capped + 1])
        has_more = probe.length > capped
        page = probe.first(capped).map { |row| { code: row['code'], name: row['name'] } }
        {
          products: page,
          returned_count: page.length,
          total_count: total_count(has_more, page.length),
          complete: !has_more
        }
      end

      # Exact resolution of ONE active top-level product (template OR standalone) by its exact
      # item_code or exact (case-insensitive) item_name, under the IDENTICAL top-level predicate used
      # by the page/count. Returns { code:, name: } for a single unique match, or nil for a blank
      # mention, no match, or an AMBIGUOUS match (more than one row) — so a caller never binds to a
      # guessed or non-unique product. A child/variant or disabled row can never be returned.
      def exact_top_level(mention)
        ensure_configured!
        normalized = mention.to_s.strip
        return nil if normalized.empty?

        rows = Marine::Catalog::Connection.select(exact_sql, [normalized, normalized.downcase])
        return nil unless rows.length == 1

        { code: rows.first['code'], name: rows.first['name'] }
      end

      private

      def ensure_configured!
        raise Marine::Catalog::Errors::CatalogUnavailableError unless Marine::Catalog::Config.configured?
      end

      # The exact total: the page size itself when the page is the whole set (no extra query), the
      # real COUNT(*) when there is more, or nil when that count cannot be obtained safely.
      def total_count(has_more, returned)
        return returned unless has_more

        rows = Marine::Catalog::Connection.select(count_sql, [])
        Integer(rows.first['total'])
      rescue StandardError
        nil
      end

      def clamp_limit(limit)
        value = limit.to_i
        return DEFAULT_PAGE if value <= 0

        [value, MAX_PAGE].min
      end

      # The single canonical top-level predicate, shared VERBATIM by page / count / exact lookup so
      # the three can never disagree about what "active top-level" means: an active row (disabled =
      # false) that is NOT a child/variant. A variant names its parent family in variant_of, so the
      # test is COALESCE(BTRIM(variant_of), '') = '' — a NULL or blank/whitespace variant_of is kept
      # (templates + standalone), only a row naming an actual parent is dropped. has_variants is
      # deliberately absent (it splits template vs standalone, both top-level — it does not
      # discriminate top-level-ness).
      TOP_LEVEL_PREDICATE = "disabled = false AND COALESCE(BTRIM(variant_of), '') = ''".freeze

      # Active top-level rows (templates + standalone; variants and disabled excluded), ordered
      # deterministically. LIMIT is bound as $1 (= page_limit + 1) so completeness is known.
      def listing_sql
        <<~SQL.squish
          SELECT item_code AS code, item_name AS name
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE #{TOP_LEVEL_PREDICATE}
          ORDER BY item_code ASC
          LIMIT $1
        SQL
      end

      # Exact count of the same active top-level set, for the completeness metadata.
      def count_sql
        <<~SQL.squish
          SELECT COUNT(*) AS total
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE #{TOP_LEVEL_PREDICATE}
        SQL
      end

      # Exact lookup over the SAME top-level predicate: match the exact item_code ($1) or the
      # case-insensitive exact item_name ($2 = lowered mention). LIMIT 2 so the caller can detect an
      # ambiguous (non-unique) match and refuse to bind rather than guessing the first row.
      def exact_sql
        <<~SQL.squish
          SELECT item_code AS code, item_name AS name
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE #{TOP_LEVEL_PREDICATE}
            AND (item_code = $1 OR LOWER(item_name) = $2)
          ORDER BY item_code ASC
          LIMIT 2
        SQL
      end
    end
  end
end
