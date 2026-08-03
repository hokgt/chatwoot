# Server-only connection configuration for the READ-ONLY Marine product catalog
# (the canonical Marine item data projected into a PostgreSQL schema). It mirrors
# the Marine::Provisioning::Config pattern: non-secret connection details come from
# MARINE_CATALOG_PG_* env vars, and the login password is read ONLY from a read-only
# secret file (MARINE_CATALOG_PG_PASSWORD_FILE) for the in-memory PG.connect call —
# never persisted, logged, echoed, or returned through the API.
#
# This connection is entirely separate from the Chatwoot application database and is
# only ever used for parameterized, SELECT-only lookups (see Connection/Repository).
module Marine
  module Catalog
    module Config
      DEFAULT_SCHEMA = 'marine_ai'.freeze
      DEFAULT_TABLE = 'item'.freeze
      DEFAULT_SSL_MODE = 'prefer'.freeze

      # Schema/table are operator-configured (never client input), but are still
      # validated against a strict identifier pattern before being interpolated into
      # SQL, as defense-in-depth. Client-supplied values (family code, query) are ALWAYS
      # passed as bind parameters, never interpolated.
      IDENTIFIER = /\A[a-z_][a-z0-9_]*\z/

      CONNECT_TIMEOUT = 5
      STATEMENT_TIMEOUT_MS = 10_000
      LOCK_TIMEOUT_MS = 5_000

      module_function

      def host = ENV.fetch('MARINE_CATALOG_PG_HOST', '').to_s
      def port = ENV.fetch('MARINE_CATALOG_PG_PORT', '5432').to_i
      def database = ENV.fetch('MARINE_CATALOG_PG_DATABASE', '').to_s
      def user = ENV.fetch('MARINE_CATALOG_PG_USER', '').to_s
      def ssl_mode = ENV.fetch('MARINE_CATALOG_PG_SSLMODE', DEFAULT_SSL_MODE)
      def password_file_path = ENV.fetch('MARINE_CATALOG_PG_PASSWORD_FILE', '').to_s

      def schema = validated_identifier(ENV.fetch('MARINE_CATALOG_PG_SCHEMA', DEFAULT_SCHEMA), DEFAULT_SCHEMA)
      def table = validated_identifier(ENV.fetch('MARINE_CATALOG_PG_TABLE', DEFAULT_TABLE), DEFAULT_TABLE)

      def qualified_table = "#{schema}.#{table}"

      # True only when every piece needed to reach the catalog is present. The
      # repository fails closed with CatalogUnavailableError when this is false.
      def configured?
        host.present? && database.present? && user.present? &&
          password_file_path.present? && File.file?(password_file_path)
      end

      # Reads the login credential from the read-only secret file. Fails closed with
      # CatalogUnavailableError (no detail about the path/reason) when missing/empty.
      def password
        value = safe_read(password_file_path)
        raise Errors::CatalogUnavailableError if value.blank?

        value
      end

      def connection_params
        {
          host: host,
          port: port,
          dbname: database,
          user: user,
          password: password,
          connect_timeout: CONNECT_TIMEOUT,
          sslmode: ssl_mode
        }
      end

      def validated_identifier(value, fallback)
        candidate = value.to_s.strip
        return fallback if candidate.empty?
        raise Errors::CatalogUnavailableError unless IDENTIFIER.match?(candidate)

        candidate
      end

      def safe_read(path)
        return nil if path.blank?

        File.read(path).to_s.strip
      rescue StandardError
        # Swallow the underlying reason on purpose; caller fails closed.
        nil
      end
    end
  end
end
