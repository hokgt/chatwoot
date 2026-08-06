# Provisions a dedicated Marine database + roles inside the EXISTING PostgreSQL
# cluster. CREATE DATABASE cannot run in a transaction, so this is implemented as
# an advisory-locked saga: each side effect is recorded, and any failure triggers
# compensating cleanup in reverse order. Nothing is marked "active" unless every
# stage — including a fresh connectivity check for the current Chatwoot app role —
# succeeds. If cleanup itself fails, a sanitized needs_manual_cleanup state is
# persisted (never with secrets) and ManualCleanupRequiredError is raised.
#
# CRITICAL ordering: the login role is created NOLOGIN (with its password already
# set) so it can never open a connection while the existing Chatwoot DB still grants
# CONNECT to PUBLIC. Only after the target DB is configured, the Chatwoot ACL is
# hardened, and a fresh app-role connectivity check passes do we ALTER ROLE ... LOGIN
# as the final PostgreSQL activation step, immediately before persisting active state.
#
# This service does NOT create the marine_ai schema. The provisioner login is granted
# CONNECT + CREATE on the new database so the ERP can create and own the marine_ai
# schema and its objects; a later Downgrade REASSIGNs those to the internal owner.
#
# The login password is used only to set the role's password and is never logged,
# persisted, or returned. The success result contains only non-secret connection
# details for the one-time popup.
module Marine
  module Provisioning
    class ProvisionService
      # Fixed 64-bit key so all provisioning actions serialize on one advisory lock.
      ADVISORY_LOCK_KEY = 728_314_907_115_204

      def initialize(database_name:, login_username:, password:, actor_id: nil)
        @database_name = database_name.to_s.strip
        @login_username = login_username.to_s.strip
        @password = password.to_s
        @actor_id = actor_id
        @trace_id = SecureRandom.uuid
      end

      def call
        validate_inputs!
        raise Errors::AlreadyProvisionedError if StateStore.exists?

        audit('provision.create', 'started')
        run_saga
        details = success_details
        audit('provision.create', 'succeeded')
        details
      rescue Errors::SanitizedError => e
        audit('provision.create', 'failed', detail: e.i18n_key)
        raise e
      rescue StandardError => e
        sanitized = ErrorSanitizer.sanitize(e, trace_id: @trace_id)
        audit('provision.create', 'failed', detail: sanitized.i18n_key)
        raise sanitized
      end

      private

      def validate_inputs!
        forbidden = [Config.app_database, Config.app_username]
        @database_name = IdentifierValidator.validate!(@database_name, label: 'Database name', extra_reserved: forbidden)
        @login_username = IdentifierValidator.validate!(@login_username, label: 'Login username', extra_reserved: forbidden)
        # The database and the login role must be distinct identifiers so hardening
        # the DB ACL never collides with the login role's grants.
        raise Errors::InvalidIdentifierError.new('Database name and login username must differ') if @database_name == @login_username

        validate_password!
        @owner_role = build_owner_role
      end

      # Validate the login password WITHOUT ever echoing its raw value. We enforce a
      # minimum length, a sane maximum byte size, and reject NUL/control characters
      # (which could truncate or smuggle bytes into the CREATE ROLE statement even
      # though the value is always passed through escape_literal).
      def validate_password!
        raise password_error('is too short') if @password.length < Config::PASSWORD_MIN_LENGTH
        raise password_error('is too long') if @password.bytesize > Config::PASSWORD_MAX_BYTES
        raise password_error('contains invalid control characters') if @password.match?(/[\u0000-\u001f\u007f]/)
      end

      def password_error(reason)
        # Message carries only a generic reason — never the password value itself.
        Errors::InvalidIdentifierError.new("Login password #{reason}")
      end

      # Auto-generated internal NOLOGIN owner; admin never supplies it. Derived from
      # the database name. When "<db>_owner" would exceed PostgreSQL's 63-byte limit
      # we build a DETERMINISTIC name that still retains an owner marker plus a hash
      # suffix, rather than blindly truncating (which for a 63-byte DB name would just
      # slice `_owner` back off and collide with the database name).
      def build_owner_role
        base = "#{@database_name}_owner"
        base = truncated_owner_name if base.bytesize > IdentifierValidator::MAX_BYTES
        owner = IdentifierValidator.validate!(base, label: 'Owner role', extra_reserved: [Config.app_database, Config.app_username])
        # Defence in depth: the internal owner must never coincide with the database
        # or the login role even after truncation/hashing.
        raise Errors::InvalidIdentifierError.new('Owner role could not be made distinct') if [@database_name, @login_username].include?(owner)

        owner
      end

      # "<prefix>_o_<8 hex>" fits in 63 bytes and stays deterministic for a given DB
      # name. The hash is derived from the full (untruncated) database name so two
      # different long DB names cannot map to the same owner role.
      def truncated_owner_name
        digest = Digest::SHA256.hexdigest(@database_name)[0, 8]
        tag = "_o_#{digest}"
        prefix_budget = IdentifierValidator::MAX_BYTES - tag.bytesize
        "#{@database_name.byteslice(0, prefix_budget)}#{tag}"
      end

      def run_saga
        @stages = []
        Connection.with_admin do |conn|
          acquire_lock!(conn)
          begin
            raise Errors::AlreadyProvisionedError if StateStore.exists?

            create_owner_role(conn)
            create_login_role(conn)
            create_database(conn)
            configure_new_database
            harden_chatwoot_database(conn)
            verify_app_connectivity!
            # LOGIN is enabled only as the FINAL PostgreSQL step, after Chatwoot's
            # PUBLIC CONNECT has been revoked and fresh app connectivity is confirmed,
            # so the new credential can never reach the Chatwoot DB through PUBLIC.
            activate_login!(conn)
            persist_active!
          rescue StandardError => e
            handle_failure(conn, e)
          ensure
            release_lock(conn)
          end
        end
      end

      def acquire_lock!(conn)
        locked = conn.exec_params('SELECT pg_try_advisory_lock($1)', [ADVISORY_LOCK_KEY]).getvalue(0, 0)
        raise Errors::LockUnavailableError unless truthy?(locked)
      end

      def release_lock(conn)
        conn.exec_params('SELECT pg_advisory_unlock($1)', [ADVISORY_LOCK_KEY])
      rescue StandardError
        nil
      end

      # Least-privilege attribute clause pinned on both roles at creation time so
      # neither the owner nor the login can ever escalate through a default attribute.
      SAFE_ROLE_ATTRIBUTES = 'NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS'.freeze

      def create_owner_role(conn)
        conn.exec("CREATE ROLE #{conn.quote_ident(@owner_role)} NOLOGIN #{SAFE_ROLE_ATTRIBUTES}")
        @stages << :owner_role
      end

      # Created NOLOGIN on purpose: the password is set now, but the role cannot open
      # a session until activate_login! flips it to LOGIN as the final step. Password
      # quoted as a literal by the driver; never interpolated raw and never logged.
      def create_login_role(conn)
        conn.exec(
          "CREATE ROLE #{conn.quote_ident(@login_username)} NOLOGIN #{SAFE_ROLE_ATTRIBUTES} " \
          "PASSWORD #{conn.escape_literal(@password)}"
        )
        @stages << :login_role
      end

      # Final PostgreSQL activation: enable LOGIN for the provisioner role. Tracked as
      # its own saga stage so an activation or subsequent state failure still drops the
      # role during compensation.
      def activate_login!(conn)
        conn.exec("ALTER ROLE #{conn.quote_ident(@login_username)} LOGIN")
        @stages << :login_activated
      end

      def create_database(conn)
        conn.exec("CREATE DATABASE #{conn.quote_ident(@database_name)} OWNER #{conn.quote_ident(@owner_role)}")
        @stages << :database
      end

      # Inside the new DB: strip PUBLIC access and give the login exactly CONNECT +
      # CREATE at the database level plus revoke PUBLIC on the default public schema.
      # We intentionally do NOT create the marine_ai schema here — the ERP creates and
      # owns it (and its objects) using the login's CREATE-on-database grant, and a
      # later Downgrade REASSIGNs that ownership to the internal NOLOGIN owner.
      def configure_new_database
        Connection.with_admin_on(@database_name) do |db|
          db.exec("REVOKE CONNECT, TEMPORARY ON DATABASE #{db.quote_ident(@database_name)} FROM PUBLIC")
          db.exec("GRANT CONNECT, CREATE ON DATABASE #{db.quote_ident(@database_name)} TO #{db.quote_ident(@login_username)}")
          db.exec('REVOKE ALL ON SCHEMA public FROM PUBLIC')
        end
        @stages << :new_db_configured
      end

      # Narrowly harden the existing Chatwoot DB on the same cluster: remove PUBLIC
      # CONNECT and explicitly (re)grant CONNECT to the running app role so live
      # sessions are unaffected and new app connections keep working.
      #
      # The REVOKE and GRANT are wrapped in a single transaction so a failure between
      # them can never leave the Chatwoot DB with PUBLIC connect revoked and no
      # replacement grant. The prior PUBLIC CONNECT state is captured BEFORE any
      # mutation so compensation can restore it exactly.
      def harden_chatwoot_database(conn)
        chatwoot = Config.app_database
        app_role = Config.app_username
        return if chatwoot.blank? || app_role.blank?

        capture_prior_chatwoot_acl(conn, chatwoot, app_role)
        conn.exec('BEGIN')
        begin
          conn.exec("REVOKE CONNECT ON DATABASE #{conn.quote_ident(chatwoot)} FROM PUBLIC")
          conn.exec("GRANT CONNECT ON DATABASE #{conn.quote_ident(chatwoot)} TO #{conn.quote_ident(app_role)}")
          conn.exec('COMMIT')
        rescue StandardError
          safe_rollback(conn)
          raise
        end
        @stages << :chatwoot_hardened
      end

      # Capture the EXACT prior CONNECT posture of the Chatwoot DB before hardening so
      # compensation can restore it precisely:
      #   * @chatwoot_prior_public_connect — whether PUBLIC held CONNECT (directly or
      #     implicitly via a NULL/default datacl).
      #   * @chatwoot_prior_app_connect — whether the app role held a DIRECT, explicit
      #     CONNECT ACL entry (independent of any implicit/owner rights).
      # When the posture cannot be determined we fail safe: assume PUBLIC had CONNECT
      # (so we restore it) and assume the app role's grant pre-existed (so we do NOT
      # revoke it) — both err toward preserving app connectivity.
      def capture_prior_chatwoot_acl(conn, dbname, app_role)
        row = conn.exec_params(<<~SQL, [dbname, app_role]).first
          SELECT d.datacl IS NULL AS acl_default,
                 COALESCE(bool_or(a.grantee = 0 AND a.privilege_type = 'CONNECT'), false) AS public_connect,
                 COALESCE(bool_or(a.grantee = r.oid AND a.privilege_type = 'CONNECT'), false) AS app_connect
          FROM pg_database d
          LEFT JOIN LATERAL aclexplode(d.datacl) a ON true
          LEFT JOIN pg_roles r ON r.rolname = $2
          WHERE d.datname = $1
          GROUP BY d.datacl, r.oid
        SQL
        if row.nil?
          @chatwoot_prior_public_connect = true
          @chatwoot_prior_app_connect = true
          return
        end

        @chatwoot_prior_public_connect = truthy?(row['acl_default']) || truthy?(row['public_connect'])
        @chatwoot_prior_app_connect = truthy?(row['app_connect'])
      end

      def safe_rollback(conn)
        conn.exec('ROLLBACK')
      rescue StandardError
        nil
      end

      def verify_app_connectivity!
        return if Connection.app_connectivity_ok?

        raise Errors::ProvisioningFailedError.new('Application connectivity check failed')
      end

      def persist_active!
        StateStore.write!(
          status: StateStore::STATUS_ACTIVE,
          database_name: @database_name,
          login_username: @login_username,
          owner_role: @owner_role,
          host: Config.admin_host,
          port: Config.admin_port,
          ssl_mode: Config.ssl_mode,
          schema: Config::PROJECTION_SCHEMA,
          privilege_level: StateStore::PRIVILEGE_ADMIN,
          provisioned_at: Time.current.iso8601
        )
      end

      # Compensate in reverse. If cleanup succeeds, re-raise a rollback error; if
      # cleanup itself fails, persist needs_manual_cleanup and raise accordingly.
      def handle_failure(conn, error)
        raise error if error.is_a?(Errors::AlreadyProvisionedError) || error.is_a?(Errors::LockUnavailableError)

        compensate(conn)
        raise ErrorSanitizer.sanitize(error, trace_id: @trace_id)
      rescue Errors::ManualCleanupRequiredError => e
        raise e
      end

      def compensate(conn)
        restore_chatwoot_acl(conn) if @stages.include?(:chatwoot_hardened)
        drop_database(conn) if @stages.include?(:database)
        drop_role(conn, @login_username) if @stages.include?(:login_role)
        drop_role(conn, @owner_role) if @stages.include?(:owner_role)
        audit('provision.rollback', 'succeeded')
      rescue StandardError => cleanup_error
        persist_manual_cleanup!(cleanup_error)
        raise Errors::ManualCleanupRequiredError
      end

      # Restore the EXACT prior CONNECT posture captured before hardening:
      #   * Re-GRANT PUBLIC CONNECT only if PUBLIC held it before (else do nothing —
      #     blindly granting would loosen the cluster beyond its original posture).
      #   * REVOKE the explicit app-role CONNECT we added during hardening if it did
      #     NOT exist beforehand. This removes only the direct ACL entry we introduced
      #     and never touches the app role's owner/implicit rights.
      def restore_chatwoot_acl(conn)
        chatwoot = Config.app_database
        app_role = Config.app_username
        conn.exec("GRANT CONNECT ON DATABASE #{conn.quote_ident(chatwoot)} TO PUBLIC") if @chatwoot_prior_public_connect
        return if @chatwoot_prior_app_connect || app_role.blank?

        conn.exec("REVOKE CONNECT ON DATABASE #{conn.quote_ident(chatwoot)} FROM #{conn.quote_ident(app_role)}")
      end

      def drop_database(conn)
        conn.exec("DROP DATABASE IF EXISTS #{conn.quote_ident(@database_name)}")
      end

      def drop_role(conn, role)
        conn.exec("DROP ROLE IF EXISTS #{conn.quote_ident(role)}")
      end

      def persist_manual_cleanup!(cleanup_error)
        sanitized = ErrorSanitizer.sanitize(cleanup_error, trace_id: @trace_id)
        StateStore.write!(
          status: StateStore::STATUS_NEEDS_MANUAL_CLEANUP,
          database_name: @database_name,
          login_username: @login_username,
          owner_role: @owner_role,
          cleanup_note: sanitized.i18n_key
        )
        audit('provision.rollback', 'failed', detail: sanitized.i18n_key)
      end

      # Non-secret connection metadata for the one-time credentials popup. The popup
      # requirements do not include a schema, so it is intentionally omitted here
      # (the projection schema is an internal detail, not connection info).
      def success_details
        {
          host: Config.admin_host,
          port: Config.admin_port,
          database_name: @database_name,
          login_username: @login_username,
          ssl_mode: Config.ssl_mode
        }
      end

      def audit(action, result, detail: nil)
        Audit.record(
          action: action, actor_id: @actor_id, result: result, trace_id: @trace_id, detail: detail,
          target: { database_name: @database_name, login_username: @login_username, owner_role: @owner_role }
        )
      end

      def truthy?(value)
        %w[t true 1].include?(value.to_s.downcase)
      end
    end
  end
end
