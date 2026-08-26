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

      # Bounded transient-failure retry for the read-only catalog. Only these two pg
      # adapter classes — a lost/failed connection and an unsendable request — are
      # retried, because every catalog operation is an idempotent, read-only SINGLE
      # SELECT whose connection this module fully owns (opened and closed here, never a
      # shared Rails pool). A momentary connectivity blip that the identical SELECT
      # succeeds through moments later is thus survived instead of fanning out to a
      # factless handoff. Nothing else is retried: syntax, permission, schema/config,
      # statement timeout / query canceled, and any other error still fail closed
      # immediately. Serialization failures cannot occur here — the session is read-only
      # but keeps the default READ COMMITTED isolation — so they are deliberately absent.
      RETRYABLE_CONNECTIVITY_ERRORS = [PG::ConnectionBad, PG::UnableToSend].freeze

      # At most one retry (two attempts total).
      MAX_RETRIES = 1

      # Runs a parameterized SELECT and returns an array of row hashes. Fails closed:
      # every non-config error is funneled into a sanitized CatalogUnavailableError. The
      # bounded transient retry lives in #attempt; only that small allowlist survives, and
      # only for the same idempotent read-only SELECT, so no side effect is ever repeated.
      def select(sql, params = [])
        raise Errors::CatalogUnavailableError unless single_select?(sql)

        attempt(sql, params, retries: MAX_RETRIES)
      rescue Errors::CatalogError
        raise
      rescue StandardError => e
        log_internal(e)
        raise Errors::CatalogUnavailableError
      end

      # One fully-owned open -> SELECT -> close cycle. On a transient connectivity error,
      # while a retry remains, it discards THIS connection (never an unrelated pool) and
      # re-attempts the SAME idempotent SELECT exactly once more; otherwise the error
      # propagates to #select's sanitizing rescue. The connection is always closed here.
      def attempt(sql, params, retries:)
        conn = open
        conn.exec_params(sql, params).to_a
      rescue *RETRYABLE_CONNECTIVITY_ERRORS => e
        raise if retries <= 0

        safe_close(conn)
        conn = nil
        log_retry(e, MAX_RETRIES - retries + 1)
        attempt(sql, params, retries: retries - 1)
      ensure
        safe_close(conn)
      end

      # True only when the SQL is exactly one SELECT statement. Never exposes the SQL.
      def single_select?(sql)
        text = sql.to_s
        SINGLE_SELECT.match?(text) && text.exclude?(';')
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

      # One secret-safe WARNING breadcrumb per retried call: operation, error class, and
      # attempt count ONLY — never SQL text, bind values, connection params, or the
      # password. Bounded to a single line (at most one retry per select).
      def log_retry(error, attempt)
        Rails.logger.warn({ tag: 'marine.catalog.retry', operation: 'select',
                            error_class: error.class.name, retry: attempt }.to_json)
      rescue StandardError
        nil
      end
    end
  end
end
