# Server-only configuration for Marine PostgreSQL provisioning.
#
# The bootstrap (admin) credential is sourced ONLY from a Docker secret file mounted
# read-only into the Rails container (MARINE_PROVISIONING_PG_PASSWORD_FILE). It is
# NEVER stored in the Chatwoot DB, InstallationConfig, Redis, logs, the frontend, the
# API, or exception messages. Deployments typically point this at the existing
# PostgreSQL superuser/app role, so the bootstrap password may be the same value the
# app already uses — the security property is that it is read only from the secret
# file for the in-memory PG.connect call, not that it is a distinct credential.
#
# Non-secret admin connection details (host/port/user/maintenance DB/SSL mode)
# come from MARINE_PROVISIONING_* env vars. Only the password comes from the file.
module Marine
  module Provisioning
    module Config
      DEFAULT_MAINTENANCE_DB = 'postgres'.freeze
      DEFAULT_SSL_MODE = 'prefer'.freeze
      # The dedicated projection schema created inside the Marine database. All
      # writer grants and the privilege matrix target this schema (never `public`).
      PROJECTION_SCHEMA = 'marine_ai'.freeze
      # Login password bounds: long enough to be meaningful, capped so a pathological
      # value can never be used as a memory/log amplification vector.
      PASSWORD_MIN_LENGTH = 12
      PASSWORD_MAX_BYTES = 128
      # Short, bounded timeouts so a stuck cluster can never hang a request thread.
      CONNECT_TIMEOUT = 5
      STATEMENT_TIMEOUT_MS = 10_000
      LOCK_TIMEOUT_MS = 5_000

      module_function

      def admin_host
        ENV.fetch('MARINE_PROVISIONING_PG_HOST', app_db_config[:host].presence || 'localhost')
      end

      def admin_port
        ENV.fetch('MARINE_PROVISIONING_PG_PORT', (app_db_config[:port] || 5432).to_s).to_i
      end

      def admin_user
        ENV.fetch('MARINE_PROVISIONING_PG_ADMIN_USER', '').to_s
      end

      def maintenance_db
        ENV.fetch('MARINE_PROVISIONING_PG_MAINTENANCE_DB', DEFAULT_MAINTENANCE_DB)
      end

      def ssl_mode
        ENV.fetch('MARINE_PROVISIONING_PG_SSLMODE', DEFAULT_SSL_MODE)
      end

      def password_file_path
        ENV.fetch('MARINE_PROVISIONING_PG_PASSWORD_FILE', '')
      end

      # Reads the bootstrap credential from the read-only secret file. Fails closed
      # with CredentialUnavailableError (no detail about the path/reason) when the
      # file is missing, empty, or unreadable. The value is never cached, logged,
      # or returned anywhere except the in-memory PG connection call.
      def bootstrap_password
        path = password_file_path
        raise Errors::CredentialUnavailableError if path.blank?

        value = safe_read(path)
        raise Errors::CredentialUnavailableError if value.blank?

        value
      end

      def configured?
        password_file_path.present? && admin_user.present? && File.file?(password_file_path)
      end

      # Non-secret snapshot for diagnostics/UI. Deliberately omits the password.
      def public_connection_details
        {
          host: admin_host,
          port: admin_port,
          maintenance_db: maintenance_db,
          ssl_mode: ssl_mode
        }
      end

      # --- Current Chatwoot application connection (the one that must never break) ---

      def app_db_config
        ActiveRecord::Base.connection_db_config.configuration_hash.symbolize_keys
      rescue StandardError
        {}
      end

      def app_database
        app_db_config[:database].to_s
      end

      def app_username
        app_db_config[:username].to_s
      end

      # Reproduces the CURRENT Chatwoot ActiveRecord connection endpoint as a libpq
      # (PG.connect) parameter hash, so a connectivity check hits the SAME database the
      # app already uses — never the provisioning admin host/port/sslmode. Values come
      # from AR's already-resolved configuration_hash (so a DATABASE_URL is honored),
      # AR keys are mapped to their libpq equivalents (database→dbname, username→user),
      # and every blank key is omitted so Unix-socket/default resolution still works.
      # Only connect_timeout is added. The password is included solely for the in-memory
      # connect call; it is never logged or exposed through a standalone accessor.
      def app_connection_params
        cfg = app_db_config
        {
          dbname: cfg[:database],
          user: cfg[:username],
          password: cfg[:password],
          host: cfg[:host],
          hostaddr: cfg[:hostaddr],
          port: cfg[:port],
          sslmode: cfg[:sslmode],
          sslcert: cfg[:sslcert],
          sslkey: cfg[:sslkey],
          sslrootcert: cfg[:sslrootcert],
          sslpassword: cfg[:sslpassword],
          options: cfg[:options],
          connect_timeout: CONNECT_TIMEOUT
        }.reject { |_key, value| blank_param?(value) }
      end

      def blank_param?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def safe_read(path)
        File.read(path).to_s.strip
      rescue StandardError
        # Swallow the underlying reason on purpose; caller raises the sanitized error.
        nil
      end
    end
  end
end
