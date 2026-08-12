# Read-only repository for the single approved general selling price of a child item.
# The business policy is fixed and non-negotiable: the ONLY price list consulted is
# 'User Price' (the sole allowed policy constant), and only a general (no-customer),
# selling, currently-valid row on an enabled selling price list qualifies. Exactly one
# distinct { price_list_rate, currency, uom } tuple yields a price; zero means the price
# is unavailable; two or more distinct tuples is a conflict. The repository NEVER selects
# an arbitrary first tuple and NEVER falls back to any other price list. Everything is
# parameterized, SELECT-only through Marine::Catalog::Connection, and fails closed with a
# sanitized CatalogUnavailableError when the catalog DB is unconfigured or unreachable.
module Marine
  module Catalog
    class PriceRepository
      # The sole permitted price-list business name. This is a fixed policy constant — not
      # client/LLM input — and is still passed to SQL as a bind parameter, never interpolated.
      USER_PRICE_LIST = 'User Price'.freeze

      # Resolves the general selling price for an exact child item_code. Result shapes:
      #   { status: :available, price_list_rate:, currency:, uom: } — exactly one COMPLETE tuple
      #   { status: :unavailable }                                   — no qualifying tuple, or an
      #                                                                incomplete one (any of rate,
      #                                                                currency, uom nil/blank)
      #   { status: :conflict }                                      — two or more tuples
      # A blank code short-circuits to :unavailable without touching the database. The
      # customer contract requires all three fields; a partial tuple fails closed as
      # :unavailable — it is never reported available.
      def price_for(child_code)
        code = child_code.to_s.strip
        return { status: :unavailable } if code.empty?

        ensure_configured!
        rows = Connection.select(price_sql, [code, USER_PRICE_LIST])
        return { status: :unavailable } if rows.empty?
        return { status: :conflict } if rows.length > 1

        row = rows.first
        rate = row['price_list_rate']
        currency = row['currency']
        uom = row['uom']
        return { status: :unavailable } if rate.blank? || currency.blank? || uom.blank?

        { status: :available, price_list_rate: rate, currency: currency, uom: uom }
      end

      private

      def ensure_configured!
        raise Errors::CatalogUnavailableError unless Config.configured?
      end

      # Fixed table names qualified by the validated schema; never client input.
      def item_price_table = "#{Config.schema}.item_price"
      def price_list_table = "#{Config.schema}.price_list"

      # DISTINCT over only the three allowlisted output columns; LIMIT 2 is enough to tell
      # a single approved tuple apart from a conflict. The price-list policy name ($2) gates
      # both item_price.price_list and the joined price_list.name.
      def price_sql
        <<~SQL.squish
          SELECT DISTINCT ip.price_list_rate AS price_list_rate,
                          ip.currency AS currency,
                          ip.uom AS uom
          FROM #{item_price_table} ip
          JOIN #{price_list_table} pl ON pl.name = ip.price_list
          WHERE ip.item_code = $1
            AND ip.price_list = $2
            AND ip.selling = true
            AND (ip.customer IS NULL OR ip.customer = '')
            AND ip.valid_from <= CURRENT_DATE
            AND (ip.valid_upto IS NULL OR ip.valid_upto >= CURRENT_DATE)
            AND pl.enabled = true
            AND pl.selling = true
          ORDER BY price_list_rate ASC, currency ASC, uom ASC
          LIMIT 2
        SQL
      end
    end
  end
end
