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
# Authoritative identity is the item_code, NEVER the item_name. The active-set query DEDUPLICATES
# on item_code (SQL `DISTINCT ON (item_code)`) BEFORE the page limit, and the total is a
# `COUNT(DISTINCT item_code)` over the SAME filter — so a duplicate physical row for one item_code
# can never appear twice in the page, inflate the total, or (in the exact lookup) manufacture a
# false ambiguity. A blank/whitespace item_code is excluded (it is not a usable identity: the dedup
# key would collapse unrelated rows into one phantom "" product).
#
# The listing is a BOUNDED PAGE with EXACT completeness metadata, never an exhaustive dump and
# never a silent truncation:
#   * a single SELECT fetches page_limit + 1 DEDUPLICATED rows, so `has_more` (and thus `complete`)
#     is known exactly from whether an extra distinct item_code came back;
#   * `returned_count` is the size of the capped (already-deduplicated) page actually returned;
#   * `total_count` is the page size itself when complete (no extra query), or a safe
#     COUNT(DISTINCT item_code) when there is more — and nil if that count cannot be obtained safely
#     (the caller stays honest about a bounded selection rather than claiming a total it does not
#     have);
#   * `has_more` is returned explicitly and is always the exact complement of `complete`
#     (`complete == !has_more`), so the caller never has to re-derive completeness.
# `limit` is clamped to [1, MAX_PAGE]; MAX_PAGE is the hard repository ceiling. Everything is
# parameterized, SELECT-only, and fails closed with CatalogUnavailableError when the catalog DB
# is unconfigured/unreachable. No UI, no provider, no state is built here.
module Marine
  module Catalog
    class ProductListingRepository # rubocop:disable Metrics/ClassLength -- cohesive read-only SQL authority for listing, category, and bounded inference queries
      # Conservative page cap aligned with the existing catalog DEFAULT_LIMIT, chosen so the bounded
      # page fits the 16 KiB Evidence packet and a useful customer reply. It is also the hard ceiling.
      MAX_PAGE = 20
      DEFAULT_PAGE = 20
      MAX_ANY_CANDIDATES = Marine::Decision::Schema::MAX_RAW_ARRAY
      MAX_ANY_CANDIDATE_BYTES = Marine::Decision::Schema::MAX_RAW_CANDIDATE_LENGTH
      MAX_INFERENCE_MATCHES = 20

      # Bounded, deterministic listing of ACTIVE TOP-LEVEL products, DEDUPLICATED on item_code. Returns:
      #   { products: [{ code:, name: }], returned_count:, total_count: (Integer|nil), complete:, has_more: }
      # complete == true means the returned page IS the whole active top-level set, and is always the
      # exact complement of has_more (complete == !has_more).
      def active_top_level(limit: DEFAULT_PAGE, item_group: nil)
        ensure_configured!
        capped = clamp_limit(limit)
        category = normalized_item_group(item_group)
        raise Marine::Catalog::Errors::CatalogUnavailableError if !item_group.nil? && category.nil?

        params = category ? [capped + 1, category] : [capped + 1]
        probe = Marine::Catalog::Connection.select(listing_sql(category: category), params)
        has_more = probe.length > capped
        page = probe.first(capped).map { |row| product_row(row) }
        {
          products: page,
          returned_count: page.length,
          total_count: total_count(has_more, page.length, category: category),
          complete: !has_more,
          has_more: has_more
        }
      rescue Marine::Catalog::Errors::CatalogUnavailableError
        raise
      rescue StandardError
        raise Marine::Catalog::Errors::CatalogUnavailableError
      end

      # Bounded authoritative company-offering categories projected from the real item_group field.
      # This deliberately returns category names only: a company-wide question must not enumerate item
      # rows. Categories are derived from the same active sellable top-level population used by listings.
      def active_item_groups(limit: DEFAULT_PAGE)
        ensure_configured!
        capped = clamp_limit(limit)
        probe = Marine::Catalog::Connection.select(item_groups_sql, [capped + 1])
        has_more = probe.length > capped
        groups = probe.first(capped).map { |row| required_item_group(row['item_group']) }
        {
          item_groups: groups,
          returned_count: groups.length,
          total_count: item_group_total(has_more, groups.length),
          complete: !has_more,
          has_more: has_more
        }
      rescue Marine::Catalog::Errors::CatalogUnavailableError
        raise
      rescue StandardError
        raise Marine::Catalog::Errors::CatalogUnavailableError
      end

      # Resolve one exact category from the catalog's item_group field. No fuzzy matching or phrase
      # rules: absent/ambiguous values return nil and the caller fails closed.
      def exact_item_group(mention)
        ensure_configured!
        normalized = normalized_item_group(mention)
        return nil if normalized.nil?

        rows = Marine::Catalog::Connection.select(exact_item_group_sql, [normalized.downcase])
        return nil unless rows.length == 1

        required_item_group(rows.first['item_group'])
      rescue Marine::Catalog::Errors::CatalogUnavailableError
        raise
      rescue StandardError
        raise Marine::Catalog::Errors::CatalogUnavailableError
      end

      # Batched exact lookups for Backend listing scope. Both inspect the complete bounded candidate
      # set in one SELECT and retain ambiguity instead of selecting an arbitrary match.
      def resolve_top_level_any(candidates)
        values = normalize_candidates(candidates)
        resolve_any(values, top_level_any_sql(values.length), :product)
      end

      def resolve_item_group_any(candidates)
        values = normalize_candidates(candidates)
        resolve_any(values, item_group_any_sql(values.length), :item_group)
      end

      # Infer a category only from eligible top-level products whose normalized item name/code contains
      # an exact token match. This is deliberately bounded and unanimous: every distinct matching
      # product must converge on one normalized Item Group with one display spelling. Missing,
      # conflicting, or overflowed evidence never guesses a category.
      def infer_item_group_from_top_level_any(candidates) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity -- bounded fail-closed convergence gates
        values = normalize_candidates(candidates).map(&:downcase).grep(/\A[[:alnum:]]+\z/).uniq
        return { status: :missing } if values.empty?

        ensure_configured!
        rows = Marine::Catalog::Connection.select(inferred_item_group_sql(values.length), values)
        return { status: :missing } if rows.empty?
        return { status: :ambiguous } if rows.length > MAX_INFERENCE_MATCHES
        return { status: :ambiguous } if rows.any? { |row| Integer(row['display_count']) != 1 }

        groups = rows.map { |row| row['normalized_group'].to_s.strip }.uniq
        displays = rows.map { |row| required_item_group(row['item_group']) }.uniq
        return { status: :ambiguous } unless groups.one? && displays.one?

        { status: :resolved, item_group: displays.first }
      rescue StandardError
        { status: :unavailable }
      end

      # Exact resolution of ONE active top-level product (template OR standalone) by its exact
      # item_code or exact (case-insensitive) item_name, under the IDENTICAL authoritative predicate
      # used by the page/count and DEDUPLICATED on item_code. Returns { code:, name: } for a single
      # unique item_code match, or nil for a blank mention, no match, or an AMBIGUOUS match (more than
      # one DISTINCT item_code) — so a caller never binds to a guessed or non-unique product.
      # Duplicate physical rows for the SAME item_code collapse to one identity and never manufacture
      # a false ambiguity. A child/variant or disabled row can never be returned.
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

      # The exact total of the SAME deduplicated authoritative set: the page size itself when the page
      # is the whole set (no extra query), the real COUNT(DISTINCT item_code) when there is more, or
      # nil when that count cannot be obtained safely.
      def total_count(has_more, returned, category: nil)
        return returned unless has_more

        params = category ? [category] : []
        rows = Marine::Catalog::Connection.select(count_sql(category: category), params)
        Integer(rows.first['total'])
      rescue StandardError
        nil
      end

      def item_group_total(has_more, returned)
        return returned unless has_more

        rows = Marine::Catalog::Connection.select(item_group_count_sql, [])
        Integer(rows.first['total'])
      rescue StandardError
        nil
      end

      def normalized_item_group(value)
        normalized = value.to_s.strip
        normalized unless normalized.empty?
      end

      def normalize_candidates(candidates)
        Array(candidates).map { |candidate| candidate.to_s.strip }
                         .reject(&:empty?)
                         .select { |value| value.bytesize <= MAX_ANY_CANDIDATE_BYTES }
                         .uniq.first(MAX_ANY_CANDIDATES)
      end

      def resolve_any(values, sql, kind)
        return { status: :missing } if values.empty?

        ensure_configured!
        rows = Marine::Catalog::Connection.select(sql, values)
        return { status: :missing } if rows.empty?
        return { status: :ambiguous } if rows.length > 1

        row = rows.first
        return { status: :resolved, code: row['code'], name: row['name'] } if kind == :product

        { status: :resolved, item_group: required_item_group(row['item_group']) }
      rescue StandardError
        { status: :unavailable }
      end

      def required_item_group(value)
        normalized_item_group(value) || raise(Marine::Catalog::Errors::CatalogUnavailableError)
      end

      def product_row(row)
        code = row['code'].to_s.strip
        raise Marine::Catalog::Errors::CatalogUnavailableError if code.empty?

        { code: code, name: row['name'] }
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
      TOP_LEVEL_PREDICATE = "disabled = false AND is_sales_item = true AND COALESCE(BTRIM(variant_of), '') = ''".freeze

      # The authoritative identity is item_code. A blank/whitespace item_code is NOT a usable
      # identity: since the active set deduplicates on item_code, a blank code would collapse
      # unrelated rows into one phantom "" product and corrupt the count/completeness semantics. It is
      # therefore excluded alongside the top-level membership test. This is an identity guard, not a
      # change to the canonical membership predicate (TOP_LEVEL_PREDICATE is preserved verbatim).
      IDENTITY_PREDICATE = "COALESCE(BTRIM(item_code), '') <> ''".freeze

      # The full authoritative filter — membership (TOP_LEVEL_PREDICATE) AND a usable item_code
      # identity — shared VERBATIM by page / count / exact lookup so the three can never disagree
      # about which rows are the active, deduplicable top-level set.
      AUTHORITATIVE_PREDICATE = "#{TOP_LEVEL_PREDICATE} AND #{IDENTITY_PREDICATE}".freeze

      # Active top-level rows (templates + standalone; variants and disabled excluded), DEDUPLICATED
      # on the authoritative item_code and ordered deterministically. `DISTINCT ON (item_code)` keeps
      # exactly one physical row per item_code; the ORDER BY leads with item_code (required by
      # DISTINCT ON and the deterministic page order) and breaks ties on item_name ASC, so the name
      # chosen for a duplicated item_code is deterministic too. LIMIT is bound as $1 (= page_limit + 1
      # distinct codes) so completeness is known exactly from the extra distinct row.
      def listing_sql(category: nil)
        category_clause = category ? 'AND LOWER(BTRIM(item_group)) = LOWER(BTRIM($2))' : nil
        <<~SQL.squish
          SELECT DISTINCT ON (item_code) item_code AS code, item_name AS name
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE #{AUTHORITATIVE_PREDICATE}
            #{category_clause}
          ORDER BY item_code ASC, item_name ASC
          LIMIT $1
        SQL
      end

      # Exact count of the SAME authoritative set, optionally narrowed to the exact item group.
      def count_sql(category: nil)
        category_clause = category ? 'AND LOWER(BTRIM(item_group)) = LOWER(BTRIM($1))' : nil
        <<~SQL.squish
          SELECT COUNT(DISTINCT item_code) AS total
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE #{AUTHORITATIVE_PREDICATE}
            #{category_clause}
        SQL
      end

      def item_groups_sql
        <<~SQL.squish
          SELECT MIN(BTRIM(item_group)) AS item_group, LOWER(BTRIM(item_group)) AS normalized_group
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE #{AUTHORITATIVE_PREDICATE}
            AND COALESCE(BTRIM(item_group), '') <> ''
          GROUP BY LOWER(BTRIM(item_group))
          ORDER BY normalized_group ASC
          LIMIT $1
        SQL
      end

      def item_group_count_sql
        <<~SQL.squish
          SELECT COUNT(DISTINCT LOWER(BTRIM(item_group))) AS total
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE #{AUTHORITATIVE_PREDICATE}
            AND COALESCE(BTRIM(item_group), '') <> ''
        SQL
      end

      def exact_item_group_sql
        <<~SQL.squish
          SELECT MIN(BTRIM(item_group)) AS item_group
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE #{AUTHORITATIVE_PREDICATE}
            AND COALESCE(BTRIM(item_group), '') <> ''
            AND LOWER(BTRIM(item_group)) = $1
          GROUP BY LOWER(BTRIM(item_group))
          LIMIT 2
        SQL
      end

      def top_level_any_sql(count)
        placeholders = (1..count).map { |index| "$#{index}" }
        identities = placeholders.map { |placeholder| "LOWER(#{placeholder})" }.join(', ')
        <<~SQL.squish
          SELECT DISTINCT ON (item_code) item_code AS code, item_name AS name
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE #{AUTHORITATIVE_PREDICATE}
            AND (LOWER(BTRIM(item_code)) IN (#{identities}) OR LOWER(BTRIM(item_name)) IN (#{identities}))
          ORDER BY item_code ASC, item_name ASC
          LIMIT 2
        SQL
      end

      def item_group_any_sql(count)
        names = (1..count).map { |index| "LOWER($#{index})" }.join(', ')
        <<~SQL.squish
          SELECT MIN(BTRIM(item_group)) AS item_group, LOWER(BTRIM(item_group)) AS normalized_group
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE #{AUTHORITATIVE_PREDICATE}
            AND COALESCE(BTRIM(item_group), '') <> ''
            AND LOWER(BTRIM(item_group)) IN (#{names})
          GROUP BY LOWER(BTRIM(item_group))
          ORDER BY normalized_group ASC
          LIMIT 2
        SQL
      end

      def inferred_item_group_sql(count) # rubocop:disable Metrics/MethodLength -- readable CTE keeps product dedup, conflicts, and bound in one query
        values = (1..count).map { |index| "($#{index})" }.join(', ')
        <<~SQL.squish
          WITH candidates(value) AS (VALUES #{values}), matches AS (
            SELECT item_code,
                   LOWER(BTRIM(item_group)) AS normalized_group,
                   MIN(BTRIM(item_group)) AS item_group,
                   COUNT(DISTINCT BTRIM(item_group)) AS display_count
            FROM #{Marine::Catalog::Config.qualified_table}
            WHERE #{AUTHORITATIVE_PREDICATE}
              AND COALESCE(BTRIM(item_group), '') <> ''
              AND EXISTS (
                SELECT 1
                FROM candidates
                WHERE candidates.value = ANY(
                  regexp_split_to_array(LOWER(CONCAT_WS(' ', item_code, item_name)), '[^[:alnum:]]+')
                )
              )
            GROUP BY item_code, LOWER(BTRIM(item_group))
          )
          SELECT item_code, normalized_group, item_group, display_count
          FROM matches
          ORDER BY item_code ASC, normalized_group ASC
          LIMIT #{MAX_INFERENCE_MATCHES + 1}
        SQL
      end

      # Exact lookup over the SAME authoritative predicate, DEDUPLICATED on item_code: match the exact
      # item_code ($1) or the case-insensitive exact item_name ($2 = lowered mention). DISTINCT ON
      # (item_code) collapses duplicate physical rows for one item_code to a single identity so they
      # cannot manufacture a false ambiguity; LIMIT 2 still lets the caller detect a genuine ambiguity
      # across DISTINCT item_codes and refuse to bind rather than guessing the first row.
      def exact_sql
        <<~SQL.squish
          SELECT DISTINCT ON (item_code) item_code AS code, item_name AS name
          FROM #{Marine::Catalog::Config.qualified_table}
          WHERE #{AUTHORITATIVE_PREDICATE}
            AND (item_code = $1 OR LOWER(item_name) = $2)
          ORDER BY item_code ASC, item_name ASC
          LIMIT 2
        SQL
      end
    end
  end
end
