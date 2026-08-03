# Thin, read-only wrapper around the `pg` gem for canonical Marine item-data
# lookups. Every connection:
#   * forces a READ-ONLY session (SET default_transaction_read_only = on),
#   * applies short connect/statement/lock timeouts so a stuck cluster can never
#     hang a request thread,
#   * runs ONLY parameterized (exec_params) SELECT statements supplied by the
#     repository, and
#   * is always closed in an ensure block.
#
# Any failure — unconfigured, unreachable, timeout, permission — is funneled into a
# sanitized CatalogUnavailableError. Raw PG errors, SQL text, and the password never
# propagate upward or get logged.
module Marine
  module Catalog
    module Connection
      module_function

      # Defense-in-depth: only a single SELECT statement is ever allowed to reach the
      # catalog, in addition to the read-only session and the parameterized repository.
      # Leading whitespace is fine; a semicolon (which could chain a second statement)
      # is not.
      SINGLE_SELECT = /\A\s*SELECT\b/i

      # Runs a parameterized SELECT and returns an array of row hashes. Fails closed.
      def select(sql, params = [])
        raise Errors::CatalogUnavailableError unless single_select?(sql)

        conn = open
        conn.exec_params(sql, params).to_a
      rescue Errors::CatalogError
        raise
      rescue StandardError => e
        log_internal(e)
        raise Errors::CatalogUnavailableError
      ensure
        safe_close(conn)
      end

      # True only when the SQL is exactly one SELECT statement. Never exposes the SQL.
      def single_select?(sql)
        text = sql.to_s
        SINGLE_SELECT.match?(text) && !text.include?(';')
      end

      # Opens a READ-ONLY, timeout-bounded connection. If PG.connect succeeds but any of
      # the session SET commands fails, the freshly opened connection is closed here so it
      # can never leak (select never receives it), then the original error is re-raised for
      # the caller to sanitize.
      def open
        conn = PG.connect(**Config.connection_params)
        conn.exec('SET default_transaction_read_only = on')
        conn.exec("SET statement_timeout = #{Config::STATEMENT_TIMEOUT_MS}")
        conn.exec("SET lock_timeout = #{Config::LOCK_TIMEOUT_MS}")
        conn
      rescue StandardError
        safe_close(conn)
        raise
      end

      # Closing is best-effort: a driver/socket close failure must never expose raw
      # PG details or mask a successful SELECT / the original sanitized failure.
      def safe_close(conn)
        conn&.close
      rescue StandardError
        nil
      end

      # Logs the class name only — never error.message (which for PG can echo SQL),
      # and never the connection params/password.
      def log_internal(error)
        Rails.logger.error({ tag: 'marine.catalog.error', error_class: error.class.name }.to_json)
      rescue StandardError
        nil
      end
    end
  end
end
