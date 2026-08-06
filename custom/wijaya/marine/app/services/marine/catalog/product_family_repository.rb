# Read-only repository over the canonical Marine item data (schema-qualified
# `marine_ai.item`, singular). A "product family" is the TEMPLATE item row itself —
# the row where `has_variants = true`. Child/variant rows (which point back via
# `variant_of`) are NOT families; existence is never inferred from a child row. This
# repository exposes exactly two operations needed for Commit 1B:
#
#   * exists?(code)         — is this an EXACT, existing product family template?
#   * search(query:, limit:) — a bounded, deterministic list for a later dropdown/API.
#
# Everything is parameterized (bind params, never string interpolation of client
# input), SELECT-only, deterministically ordered by item_code, and fails closed with a
# sanitized CatalogUnavailableError when the catalog DB is unconfigured or unreachable.
# No UI is built here.
module Marine
  module Catalog
    class ProductFamilyRepository
      MAX_LIMIT = 50
      DEFAULT_LIMIT = 20
      MAX_QUERY_LENGTH = 100

      # Exact-match existence check for a single product family template. Returns false
      # for a blank code without touching the database. Only a template row
      # (has_variants = true) counts as an existing family.
      def exists?(family_code)
        code = family_code.to_s.strip
        return false if code.empty?

        ensure_configured!
        Connection.select(exists_sql, [code]).any?
      end

      # Bounded, deterministic product-family lookup over template rows. `query` is an
      # optional case-insensitive filter on the family item_code or item_name, normalized
      # and truncated to MAX_QUERY_LENGTH; `limit` is clamped to [1, MAX_LIMIT]. Returns
      # an array of { code:, name: } hashes.
      def search(query: nil, limit: DEFAULT_LIMIT)
        ensure_configured!
        normalized = normalize_query(query)
        rows = Connection.select(search_sql, [normalized, like_pattern(normalized), clamp_limit(limit)])
        rows.map { |row| { code: row['code'], name: row['name'] } }
      end

      private

      def ensure_configured!
        raise Errors::CatalogUnavailableError unless Config.configured?
      end

      def exists_sql
        "SELECT 1 FROM #{Config.qualified_table} WHERE item_code = $1 AND has_variants = true LIMIT 1"
      end

      def search_sql
        <<~SQL.squish
          SELECT item_code AS code, item_name AS name
          FROM #{Config.qualified_table}
          WHERE has_variants = true
            AND ($1 = '' OR item_code ILIKE $2 OR item_name ILIKE $2)
          ORDER BY item_code ASC
          LIMIT $3
        SQL
      end

      # Trims surrounding whitespace and truncates to MAX_QUERY_LENGTH so an
      # oversized client query can never build a pathological LIKE pattern.
      def normalize_query(query)
        query.to_s.strip[0, MAX_QUERY_LENGTH].to_s
      end

      def clamp_limit(limit)
        value = limit.to_i
        return DEFAULT_LIMIT if value <= 0

        [value, MAX_LIMIT].min
      end

      # Escapes LIKE wildcards in the client query so they are matched literally.
      def like_pattern(query)
        "%#{query.gsub(/[\\%_]/) { |char| "\\#{char}" }}%"
      end
    end
  end
end
