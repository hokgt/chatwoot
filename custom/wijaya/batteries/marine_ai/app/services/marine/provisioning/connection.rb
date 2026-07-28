# Thin wrapper around the `pg` gem for provisioning work. Every connection uses
# short connect/statement/lock timeouts and is always closed in an ensure block so
# a stuck cluster can never leak connections or hang a worker.
#
# The bootstrap password is passed straight from Config.bootstrap_password into the
# PG.connect call and is never held in an instance variable, logged, or returned.
module Marine
  module Provisioning
    module Connection
      module_function

      # Opens an admin connection (existing superuser) to the maintenance database
      # and yields the raw PG::Connection. Used for CREATE ROLE / CREATE DATABASE,
      # which cannot run inside a transaction. Always closes.
      def with_admin(&)
        connect(dbname: Config.maintenance_db, user: Config.admin_user, password: Config.bootstrap_password, &)
      end

      # Opens an admin connection to a specific (already-created) database so we can
      # configure schema/PUBLIC grants inside it. Always closes.
      def with_admin_on(dbname, &)
        connect(dbname: dbname, user: Config.admin_user, password: Config.bootstrap_password, &)
      end

      # Verifies the CURRENT Chatwoot application role can still open a fresh
      # connection to its OWN database, using the app's real ActiveRecord connection
      # endpoint (host/port/ssl/etc.) — NOT the provisioning admin host/port/sslmode.
      # Returns true/false; never raises PG details upward and never logs the password.
      def app_connectivity_ok?
        conn = PG.connect(**Config.app_connection_params)
        conn.exec('SELECT 1')
        true
      rescue StandardError
        false
      ensure
        conn&.close
      end

      # rubocop:disable Metrics/ParameterLists
      def connect(dbname:, user:, password:, host: Config.admin_host, port: Config.admin_port)
        conn = PG.connect(
          host: host,
          port: port,
          dbname: dbname,
          user: user,
          password: password,
          connect_timeout: Config::CONNECT_TIMEOUT,
          sslmode: Config.ssl_mode
        )
        apply_timeouts(conn)
        yield conn
      ensure
        conn&.close
      end
      # rubocop:enable Metrics/ParameterLists

      def apply_timeouts(conn)
        conn.exec("SET statement_timeout = #{Config::STATEMENT_TIMEOUT_MS}")
        conn.exec("SET lock_timeout = #{Config::LOCK_TIMEOUT_MS}")
      end
    end
  end
end
