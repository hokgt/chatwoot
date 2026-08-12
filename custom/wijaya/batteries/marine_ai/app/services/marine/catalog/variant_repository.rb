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

      # Exact child lookup within a family: variant_of = family AND item_code = child, on
      # an active (disabled = false) row. LIMIT 2 distinguishes a unique child from an
      # ambiguous one. Returns { code: } (row-derived) only when exactly one child matches;
      # returns nil for zero OR multiple matches — fails closed, never picks a first row.
      def resolve_child(family_code, child_code)
        family = family_code.to_s.strip
        child = child_code.to_s.strip
        return nil if family.empty? || child.empty?

        ensure_configured!
        rows = Connection.select(resolve_child_sql, [family, child])
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
        rows = Connection.select(attribute_names_sql, [family, MAX_ATTRIBUTE_NAMES])
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
        rows = Connection.select(resolve_by_attribute_sql, [family, name, attr_value])
        return nil unless rows.length == 1

        { code: rows.first['code'] }
      end

      private

      def ensure_configured!
        raise Errors::CatalogUnavailableError unless Config.configured?
      end

      # The item table honors the operator-configured table name; the variant-attribute
      # table is a fixed name qualified by the validated schema. Neither is client input.
      def item_table = Config.qualified_table
      def attribute_table = "#{Config.schema}.item_variant_attribute"

      def resolve_child_sql
        <<~SQL.squish
          SELECT item_code AS code
          FROM #{item_table}
          WHERE variant_of = $1 AND item_code = $2 AND disabled = false
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
