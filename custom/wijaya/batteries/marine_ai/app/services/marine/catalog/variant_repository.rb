# Read-only repository over canonical Marine variant data. A "variant" (child) item is
# a row in the item table that points back to its family template via `variant_of`; the
# per-variant attribute name/value pairs live in `item_variant_attribute`. Every
# operation is parameterized (bind params, never interpolation of client input),
# SELECT-only through Marine::Catalog::Connection, deterministically ordered, bounded,
# and fails closed with a sanitized CatalogUnavailableError when the catalog DB is
# unconfigured or unreachable. Child item codes are ALWAYS taken from a query row — they
# are never constructed or concatenated from a family code and an attribute value.
module Marine
  module Catalog
    class VariantRepository
      # Conservative upper bound on the distinct attribute names returned for a family, so
      # a misconfigured catalog can never stream an unbounded result set. Not a business
      # limit — just a defensive ceiling.
      MAX_ATTRIBUTE_NAMES = 50

      # Defensive bounds on the batched exact child-code candidate set for #resolve_child_any. The
      # caller already bounds candidates to 32 (Schema::MAX_RAW_ARRAY) and 120 bytes
      # (Schema::MAX_RAW_CANDIDATE_LENGTH); these are repository backstops so a hostile oversized list
      # can never build a pathological IN-list. An over-120-byte candidate is DROPPED (never sliced
      # into a prefix that could match a DIFFERENT, shorter child code).
      MAX_ANY_CANDIDATES = 32
      MAX_ANY_CANDIDATE_BYTES = 120

      # Case-insensitive child lookup within a family: variant_of = family (exact) AND
      # LOWER(item_code) = LOWER(child), on an active (disabled = false) row. LIMIT 2
      # distinguishes a unique child from an ambiguous one — two active rows differing only by
      # case (e.g. LF-3 and lf-3) stay two rows and fail closed; they are never collapsed.
      # Returns { code: } (row-derived) only when exactly one child matches; returns nil for
      # zero OR multiple matches — fails closed, never picks a first row.
      def resolve_child(family_code, child_code)
        family = family_code.to_s.strip
        child = child_code.to_s.strip
        return nil if family.empty? || child.empty?

        ensure_configured!
        rows = Marine::Catalog::Connection.select(resolve_child_sql, [family, child])
        return nil unless rows.length == 1

        { code: rows.first['code'] }
      end

      # Distinct attribute names available for a family's variants, deterministically
      # ordered and bounded by MAX_ATTRIBUTE_NAMES. Attribute names come entirely from the
      # query rows — none are hardcoded. Returns an array of name strings (empty for a
      # blank family, without touching the database).
      def attribute_names(family_code)
        family = family_code.to_s.strip
        return [] if family.empty?

        ensure_configured!
        rows = Marine::Catalog::Connection.select(attribute_names_sql, [family, MAX_ATTRIBUTE_NAMES])
        rows.pluck('name')
      end

      # Exact resolution of a single active child by one attribute name/value within a
      # family, joining ONLY item and item_variant_attribute on a.parent = i.name. LIMIT 2
      # distinguishes unique from ambiguous. Returns { code: } (row-derived) only when
      # exactly one child matches; returns nil for zero OR multiple matches — fails closed.
      def resolve_by_attribute(family_code, attribute, value)
        family = family_code.to_s.strip
        name = attribute.to_s.strip
        attr_value = value.to_s.strip
        return nil if family.empty? || name.empty? || attr_value.empty?

        ensure_configured!
        rows = Marine::Catalog::Connection.select(resolve_by_attribute_sql, [family, name, attr_value])
        return nil unless rows.length == 1

        { code: rows.first['code'] }
      end

      # Batched exact child resolution within a family over a BOUNDED candidate set, in a SINGLE
      # parameterized SELECT (never an N-query loop). Matches an active child item_code
      # case-insensitively (variant_of = family AND disabled = false) against the candidates — NEVER a
      # display label or attribute value. LIMIT 2 tells a unique child apart from an ambiguous one.
      # Two active rows differing only by case stay distinct (never deduped by LOWER). Returns a
      # typed outcome:
      #   { status: :resolved, code: } — exactly one distinct active child matched
      #   { status: :missing }         — no active child matched (or a blank family/candidate set)
      #   { status: :ambiguous }       — two or more distinct active children matched
      #   { status: :unavailable }     — catalog DB unconfigured/unreachable (fail closed)
      # Child item codes are always row-derived; the family and every candidate are bind params.
      def resolve_child_any(family_code, candidates)
        family = family_code.to_s.strip
        values = normalize_candidates(candidates)
        return { status: :missing } if family.empty? || values.empty?

        ensure_configured!
        rows = Marine::Catalog::Connection.select(resolve_child_any_sql(values.length), [family, *values])
        classify_resolution(rows) { |row| { code: row['code'] } }
      rescue Marine::Catalog::Errors::CatalogUnavailableError
        { status: :unavailable }
      end

      private

      def ensure_configured!
        raise Marine::Catalog::Errors::CatalogUnavailableError unless Marine::Catalog::Config.configured?
      end

      # Bounded, deduped, blank-rejected candidate strings for the batched child lookup. An
      # over-MAX_ANY_CANDIDATE_BYTES candidate is DROPPED (never sliced into a prefix), then the set is
      # deduped and capped at MAX_ANY_CANDIDATES. The byte bound keeps multibyte candidates safe.
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

      # Case-insensitive active child match within the family over the candidate binds:
      # LOWER(item_code) IN (LOWER($2), ...). $1 is the family (matched exactly); $2..$(n+1) are the
      # candidate child codes. The placeholder list is generated from the validated candidate COUNT —
      # never a client value — so the statement stays parameterized. Result rows are NOT deduped by
      # LOWER(item_code): two active rows differing only by case stay distinct and fail closed to :ambiguous.
      def resolve_child_any_sql(count)
        placeholders = (2..(count + 1)).map { |i| "LOWER($#{i})" }.join(', ')
        <<~SQL.squish
          SELECT item_code AS code
          FROM #{item_table}
          WHERE variant_of = $1 AND disabled = false AND LOWER(item_code) IN (#{placeholders})
          ORDER BY item_code ASC
          LIMIT 2
        SQL
      end

      # The item table honors the operator-configured table name; the variant-attribute
      # table is a fixed name qualified by the validated schema. Neither is client input.
      def item_table = Marine::Catalog::Config.qualified_table
      def attribute_table = "#{Marine::Catalog::Config.schema}.item_variant_attribute"

      def resolve_child_sql
        <<~SQL.squish
          SELECT item_code AS code
          FROM #{item_table}
          WHERE variant_of = $1 AND LOWER(item_code) = LOWER($2) AND disabled = false
          ORDER BY item_code ASC
          LIMIT 2
        SQL
      end

      # The MAX_ATTRIBUTE_NAMES ceiling is a fixed constant, but is still passed as a bind
      # parameter ($2) rather than interpolated — no value ever reaches the SQL text.
      def attribute_names_sql
        <<~SQL.squish
          SELECT DISTINCT attribute AS name
          FROM #{attribute_table}
          WHERE variant_of = $1 AND disabled = false
          ORDER BY attribute ASC
          LIMIT $2
        SQL
      end

      def resolve_by_attribute_sql
        <<~SQL.squish
          SELECT i.item_code AS code
          FROM #{item_table} i
          JOIN #{attribute_table} a ON a.parent = i.name
          WHERE i.variant_of = $1
            AND a.variant_of = $1
            AND a.attribute = $2
            AND a.attribute_value = $3
            AND i.disabled = false
            AND a.disabled = false
          ORDER BY i.item_code ASC
          LIMIT 2
        SQL
      end
    end
  end
end
