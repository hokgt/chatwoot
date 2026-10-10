# Read-only repository for the deterministic GENERAL selling price RANGE across every active
# child of a validated product family. It reuses the EXACT, non-negotiable qualifying-tuple policy
# of the single-child Marine::Catalog::PriceRepository, field for field, so the range can never be
# cleaner than the exact per-variant follow-up it grounds: the ONLY price list consulted is
# 'User Price', and a row qualifies only when it is a general (no-customer), selling, currently-valid
# tuple on an enabled selling price list. It applies NO extra range-only restriction the exact
# lookup lacks (no packing-unit filter, no item-price/price-list currency-match, no stock-UOM join),
# so any tuple the exact lookup would see for a variant the range sees too — and an extra tuple that
# would make the exact lookup ambiguous makes the range a per-variant conflict, never a filtered-away
# clean range. It NEVER consults Partner Price, a Lead Type, a customer-specific row, or a fallback list.
#
# The range is computed ONLY when EVERY active variant resolves to exactly ONE distinct qualifying
# tuple and all variants share a single currency and UOM. A variant with no qualifying price
# (missing), a variant with two or more distinct tuples (conflict), a non-positive/non-exact
# amount, or a heterogeneous currency/UOM across variants fails CLOSED to :unavailable/:conflict —
# a variant is NEVER silently dropped and a partial range is never invented. Result shapes:
#   { status: :available, min:, max:, currency:, uom: } — one exact tuple per active variant
#   { status: :unavailable }                            — no active variant, a missing/invalid price
#   { status: :conflict }                               — a per-variant conflict, or a mixed
#                                                          currency/UOM across variants
#
# Everything is parameterized (bind params, never interpolation of client input), a SINGLE
# SELECT-only statement through Marine::Catalog::Connection, and fails closed with a sanitized
# CatalogUnavailableError when the catalog DB is unconfigured or unreachable. Amounts are compared
# and returned as EXACT decimal strings via BigDecimal — never a Float, never rounded.
module Marine
  module Catalog
    class PriceRangeRepository
      # The sole permitted price-list business name — the SAME fixed policy constant the exact
      # single-child lookup uses. Not client/LLM input; still bound as a parameter, never interpolated.
      USER_PRICE_LIST = Marine::Catalog::PriceRepository::USER_PRICE_LIST

      # A non-negative decimal STRING with no sign, exponent, or grouping — the exact, losslessly
      # representable amount form. Anything else (a sign, exponent, blank, or garbage) is rejected.
      AMOUNT_STRING = /\A\d+(?:\.\d+)?\z/

      # Resolves the family price range for a validated family_code. A blank code short-circuits to
      # :unavailable without touching the database.
      def range_for(family_code)
        family = family_code.to_s.strip
        return { status: :unavailable } if family.empty?

        ensure_configured!
        rows = Marine::Catalog::Connection.select(range_sql, [family, USER_PRICE_LIST])
        summarize(rows)
      end

      private

      def ensure_configured!
        raise Marine::Catalog::Errors::CatalogUnavailableError unless Marine::Catalog::Config.configured?
      end

      # Group the per-(variant, tuple) rows by active variant and require EXACTLY one distinct
      # qualifying tuple per variant. A variant that fails closed short-circuits the whole family; no
      # active variant at all fails closed to :unavailable.
      def summarize(rows)
        grouped = rows.group_by { |row| row['item_code'] }
        return { status: :unavailable } if grouped.empty?

        tuples = []
        grouped.each_value do |variant_rows|
          result = variant_tuple(variant_rows)
          return result if result.is_a?(Hash) # a fail-closed status short-circuits the family

          tuples << result
        end

        reduce_tuples(tuples)
      end

      # The single qualifying [rate, currency, uom] tuple for one active variant, or a fail-closed
      # status hash. A LEFT JOIN miss (no qualifying price) surfaces as a single row whose 'matched'
      # marker is nil; those rows are dropped, and a variant left with no matched tuple is missing ->
      # :unavailable. Rows are otherwise kept REGARDLESS of rate: a real qualifying item_price row can
      # carry a NULL rate, and it is a genuine tuple, distinct from a join miss — the exact
      # PriceRepository#price_for sees it as a distinct DISTINCT row too. So a lone matched NULL-rate
      # tuple passes the count check and then fails the exact amount validation downstream
      # (:unavailable), while a matched NULL-rate tuple ALONGSIDE a valid one is two distinct tuples ->
      # :conflict — never silently filtered away, so the range is never cleaner than the exact lookup.
      # Identical duplicate rows collapse via uniq (defense-in-depth over the subquery DISTINCT).
      def variant_tuple(variant_rows)
        matched = variant_rows.reject { |row| row['matched'].nil? }
        return { status: :unavailable } if matched.empty?

        distinct = matched.map { |row| [row['price_list_rate'].to_s, row['currency'], row['uom']] }.uniq
        return { status: :conflict } if distinct.length > 1

        distinct.first
      end

      # Enforce a single homogeneous currency + UOM across variants and a positive exact amount for
      # each, then return the exact min/max range. Equal endpoints collapse to a single amount string.
      def reduce_tuples(tuples)
        currency = homogeneous(tuples.map { |tuple| presence(tuple[1]) })
        uom = homogeneous(tuples.map { |tuple| presence(tuple[2]) })
        status = field_status([currency, uom])
        return { status: status } if status

        amounts = tuples.map { |tuple| canonical_amount(tuple[0]) }
        return { status: :unavailable } if amounts.any?(&:nil?)

        min_amount, max_amount = min_max_amounts(amounts)
        { status: :available, min: min_amount, max: max_amount, currency: currency, uom: uom }
      end

      # The fail-closed status for the shared currency/UOM fields: :unavailable when either is
      # missing (blank), :conflict when either is mixed across variants, else nil (both resolved).
      def field_status(fields)
        return :unavailable if fields.include?(:missing)
        return :conflict if fields.include?(:mixed)

        nil
      end

      # The single shared value of a per-variant field across all variants: :missing when any value is
      # blank, :mixed when two or more distinct values appear, else the one shared value.
      def homogeneous(values)
        return :missing if values.any?(&:nil?)
        return :mixed if values.uniq.length > 1

        values.first
      end

      # The exact min and max amount strings selected by BigDecimal value; numerically equal endpoints
      # (any scale) collapse to a single string so the caller renders one amount. Never a Float.
      def min_max_amounts(amounts)
        decimals = amounts.map { |amount| BigDecimal(amount) }
        min_decimal, max_decimal = decimals.minmax
        min_amount = amounts[decimals.index(min_decimal)]
        max_amount = min_decimal == max_decimal ? min_amount : amounts[decimals.index(max_decimal)]
        [min_amount, max_amount]
      end

      # The exact canonical amount string, or nil when it is not a positive, exactly representable
      # decimal (a sign, exponent, blank, garbage, zero, or negative all fail closed). Never a Float.
      def canonical_amount(raw)
        value = raw.to_s.strip
        return nil unless value.match?(AMOUNT_STRING)

        BigDecimal(value).positive? ? value : nil
      rescue ArgumentError
        nil
      end

      def presence(value)
        return nil unless value.is_a?(String)

        stripped = value.strip
        stripped.empty? ? nil : stripped
      end

      # Fixed table names qualified by the validated schema/table; never client input.
      def item_table = Marine::Catalog::Config.qualified_table
      def item_price_table = "#{Marine::Catalog::Config.schema}.item_price"
      def price_list_table = "#{Marine::Catalog::Config.schema}.price_list"

      # ONE parameterized SELECT. The inner DISTINCT subquery (#qualifying_tuples_sql) is the set of
      # qualifying User Price tuples, each carrying a constant TRUE match marker; the outer LEFT JOIN
      # keeps EVERY active child (variant_of = $1, disabled = false) — including those with no
      # qualifying price — joined on item_code ALONE (no stock-UOM restriction the exact lookup lacks).
      # A missing price surfaces as a single row with a NULL 'matched' marker (a join miss, never a
      # silently dropped variant), which the summarizer tells apart from a genuine qualifying tuple that
      # merely has a NULL rate; a variant carrying tuples in more than one UOM surfaces as a conflict
      # exactly as the exact lookup would. $1 = family code, $2 = the User Price policy. Both bind
      # params; schema/table are validated identifiers.
      def range_sql
        <<~SQL.squish
          SELECT i.item_code AS item_code,
                 q.price_list_rate AS price_list_rate,
                 q.currency AS currency,
                 q.uom AS uom,
                 q.matched AS matched
          FROM #{item_table} i
          LEFT JOIN (#{qualifying_tuples_sql}) q ON q.item_code = i.item_code
          WHERE i.variant_of = $1
            AND i.disabled = false
          ORDER BY i.item_code ASC, q.price_list_rate ASC, q.currency ASC, q.uom ASC
        SQL
      end

      # The DISTINCT set of qualifying User Price tuples, using the EXACT same WHERE contract as
      # Marine::Catalog::PriceRepository#price_sql (only the item_code = $1 filter is deferred to the
      # outer join so every active variant is scanned): general (no-customer), selling, currently
      # valid, on an enabled selling price list. NO packing-unit filter and NO item-price/price-list
      # currency-match — those are restrictions the exact lookup does not apply, so applying them here
      # would let the range be cleaner than the exact follow-up. DISTINCT collapses identical duplicate
      # rows so they count as one tuple. A constant TRUE match marker rides along so the outer LEFT JOIN
      # can tell a genuine qualifying tuple (marker present, even with a NULL rate) apart from a join
      # miss (marker NULL); the constant does not affect DISTINCT grouping.
      def qualifying_tuples_sql
        <<~SQL.squish
          SELECT DISTINCT ip.item_code AS item_code,
                          ip.price_list_rate AS price_list_rate,
                          ip.currency AS currency,
                          ip.uom AS uom,
                          TRUE AS matched
          FROM #{item_price_table} ip
          JOIN #{price_list_table} pl ON pl.name = ip.price_list
          WHERE ip.price_list = $2
            AND ip.selling = true
            AND (ip.customer IS NULL OR ip.customer = '')
            AND ip.valid_from <= CURRENT_DATE
            AND (ip.valid_upto IS NULL OR ip.valid_upto >= CURRENT_DATE)
            AND pl.enabled = true
            AND pl.selling = true
        SQL
      end
    end
  end
end
