# Read-only repository for a child item's stock AVAILABILITY — a binary status only.
# By design a raw numeric stock quantity NEVER crosses the PostgreSQL boundary: the
# aggregate SUM(actual_qty) over ALL bins for the item is collapsed to the literal
# 'available' / 'empty' inside the database, and Ruby only ever sees that status string.
# There is deliberately no warehouse join or filter — availability is the total across
# every bin. Parameterized, SELECT-only through Marine::Catalog::Connection, and fails
# closed with a sanitized CatalogUnavailableError when the catalog DB is unconfigured,
# unreachable, or returns an unexpected status.
module Marine
  module Catalog
    class StockRepository
      # Returns :available when the summed actual_qty across all bins is positive, else
      # :empty (which also covers the no-bin case). A blank code short-circuits to :empty.
      # Any unexpected status value fails closed with CatalogUnavailableError.
      def status_for(child_code)
        code = child_code.to_s.strip
        return :empty if code.empty?

        ensure_configured!
        rows = Connection.select(status_sql, [code])
        case rows.first && rows.first['status']
        when 'available' then :available
        when 'empty' then :empty
        else
          raise Errors::CatalogUnavailableError
        end
      end

      private

      def ensure_configured!
        raise Errors::CatalogUnavailableError unless Config.configured?
      end

      # Fixed table name qualified by the validated schema; never client input.
      def bin_table = "#{Config.schema}.bin"

      # Aggregates actual_qty across ALL bins for the item and returns ONLY a binary status
      # field — no numeric quantity is ever selected or returned. COALESCE handles the
      # no-bin case (SUM over zero rows is NULL -> 0 -> 'empty').
      def status_sql
        <<~SQL.squish
          SELECT CASE WHEN COALESCE(SUM(actual_qty), 0) > 0 THEN 'available' ELSE 'empty' END AS status
          FROM #{bin_table}
          WHERE item_code = $1
        SQL
      end
    end
  end
end
