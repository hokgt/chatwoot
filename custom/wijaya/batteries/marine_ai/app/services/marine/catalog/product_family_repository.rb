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

      # Defensive bounds on the batched exact-lookup candidate set for #resolve_exact_any. The caller
      # (the Phase 2A CatalogCandidateResolver) already bounds candidates to 32 (Schema::MAX_RAW_ARRAY)
      # and 120 bytes (Schema::MAX_RAW_CANDIDATE_LENGTH); these are repository-local backstops so a
      # hostile oversized list can never build a pathological IN-list. An over-120-byte candidate is
      # DROPPED (never sliced into a prefix that could match a DIFFERENT, shorter identifier).
      MAX_ANY_CANDIDATES = 32
      MAX_ANY_CANDIDATE_BYTES = 120

      # Exact-match existence check for a single product family template. Returns false
      # for a blank code without touching the database. Only a template row
      # (has_variants = true) counts as an existing family.
      def exists?(family_code)
        code = family_code.to_s.strip
        return false if code.empty?

        ensure_configured!
        Marine::Catalog::Connection.select(exists_sql, [code]).any?
      end

      # Bounded, deterministic product-family lookup over template rows. `query` is an
      # optional case-insensitive filter on the family item_code or item_name, normalized
      # and truncated to MAX_QUERY_LENGTH; `limit` is clamped to [1, MAX_LIMIT]. Returns
      # an array of { code:, name: } hashes.
      def search(query: nil, limit: DEFAULT_LIMIT)
        ensure_configured!
        normalized = normalize_query(query)
        rows = Marine::Catalog::Connection.select(search_sql, [normalized, like_pattern(normalized), clamp_limit(limit)])
        rows.map { |row| { code: row['code'], name: row['name'] } }
      end

      # Deterministic exact resolution to a SINGLE active family template. Matches an
      # exact item_code OR a case-insensitive exact item_name, requiring a template row
      # (has_variants = true) that is active (disabled = false). Bounded by LIMIT 2 so a
      # unique family can be told apart from an ambiguous one. Returns { code:, name: }
      # ONLY when exactly one row matches; returns nil for zero OR multiple matches — it
      # fails closed and never returns an arbitrary first row. The client identifier is
      # always passed as a bind parameter, never interpolated into SQL.
      def resolve_exact(identifier)
        value = identifier.to_s.strip
        return nil if value.empty?

        ensure_configured!
        rows = Marine::Catalog::Connection.select(resolve_exact_sql, [value])
        return nil unless rows.length == 1

        row = rows.first
        { code: row['code'], name: row['name'] }
      end

      # Bounded, deterministic list of ACTIVE family templates (has_variants = true AND
      # disabled = false). `query` is an optional case-insensitive filter on item_code or
      # item_name, normalized/truncated exactly like #search; `limit` is clamped to
      # [1, MAX_LIMIT]. Returns an array of { code:, name: } hashes ordered by item_code.
      def active_candidates(query: nil, limit: DEFAULT_LIMIT)
        ensure_configured!
        normalized = normalize_query(query)
        rows = Marine::Catalog::Connection.select(active_candidates_sql, [normalized, like_pattern(normalized), clamp_limit(limit)])
        rows.map { |row| { code: row['code'], name: row['name'] } }
      end

      # Batched exact resolution over a BOUNDED candidate set, in a SINGLE parameterized SELECT
      # (never an N-query loop). Matches an exact item_code OR a case-insensitive exact item_name
      # against the candidates, requiring an active template row (has_variants = true AND
      # disabled = false). LIMIT 2 is enough to tell a unique family apart from an ambiguous one.
      # Returns a typed outcome:
      #   { status: :resolved, code:, name: } — exactly one distinct active family matched
      #   { status: :missing }                — no active family matched (or a blank candidate set)
      #   { status: :ambiguous }              — two or more distinct active families matched
      #   { status: :unavailable }            — catalog DB unconfigured/unreachable (fail closed)
      # Every candidate is passed as a bind parameter; only the generated placeholder count ever
      # reaches the SQL text, never a client value. The caller decides whether a NAME match is
      # authoritative (the one-token display-name collision guard) by inspecting the resolved row.
      def resolve_exact_any(candidates)
        values = normalize_candidates(candidates)
        return { status: :missing } if values.empty?

        ensure_configured!
        rows = Marine::Catalog::Connection.select(resolve_exact_any_sql(values.length), values)
        classify_resolution(rows) { |row| { code: row['code'], name: row['name'] } }
      rescue Marine::Catalog::Errors::CatalogUnavailableError
        { status: :unavailable }
      end

      private

      def ensure_configured!
        raise Marine::Catalog::Errors::CatalogUnavailableError unless Marine::Catalog::Config.configured?
      end

      # Bounded, deduped, blank-rejected candidate strings for the batched lookup. Each is trimmed;
      # an over-MAX_ANY_CANDIDATE_BYTES candidate is DROPPED (never sliced into a prefix), then the set
      # is deduped and capped at MAX_ANY_CANDIDATES. The byte bound keeps multibyte candidates safe.
      def normalize_candidates(candidates)
        Array(candidates).map { |candidate| candidate.to_s.strip }
                         .reject(&:empty?)
                         .select { |value| value.bytesize <= MAX_ANY_CANDIDATE_BYTES }
                         .uniq.first(MAX_ANY_CANDIDATES)
      end

      # Map the (0, 1, 2) bounded rows to the typed outcome; the block builds the :resolved payload.
      def classify_resolution(rows)
        return { status: :missing } if rows.empty?
        return { status: :ambiguous } if rows.length > 1

        { status: :resolved }.merge(yield(rows.first))
      end

      # Exact item_code OR case-insensitive exact item_name match over the candidate binds. The
      # placeholder list ($1..$n) is generated from the validated candidate COUNT — never from a
      # client value — so the statement stays fully parameterized. LIMIT 2 distinguishes unique
      # from ambiguous.
      def resolve_exact_any_sql(count)
        placeholders = (1..count).map { |i| "$#{i}" }
        code_list = placeholders.join(', ')
        name_list = placeholders.map { |placeholder| "LOWER(#{placeholder})" }.join(', ')
        <<~SQL.squish
          SELECT item_code AS code, item_name AS name
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE has_variants = true
            AND disabled = false
            AND (item_code IN (#{code_list}) OR LOWER(item_name) IN (#{name_list}))
          ORDER BY item_code ASC
          LIMIT 2
        SQL
      end

      def exists_sql
        "SELECT 1 FROM #{Marine::Catalog::Config.qualified_table} WHERE item_code = $1 AND has_variants = true LIMIT 1"
      end

      def search_sql
        <<~SQL.squish
          SELECT item_code AS code, item_name AS name
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE has_variants = true
            AND ($1 = '' OR item_code ILIKE $2 OR item_name ILIKE $2)
          ORDER BY item_code ASC
          LIMIT $3
        SQL
      end

      # Active family template, matched by exact item_code OR case-insensitive exact
      # item_name; LIMIT 2 lets the caller tell a unique match apart from an ambiguous one.
      def resolve_exact_sql
        <<~SQL.squish
          SELECT item_code AS code, item_name AS name
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE has_variants = true
            AND disabled = false
            AND (item_code = $1 OR LOWER(item_name) = LOWER($1))
          ORDER BY item_code ASC
          LIMIT 2
        SQL
      end

      def active_candidates_sql
        <<~SQL.squish
          SELECT item_code AS code, item_name AS name
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE has_variants = true
            AND disabled = false
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
