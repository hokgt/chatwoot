# Privilege lifecycle for the provisioned Marine login role. Two explicit,
# admin-triggered actions, each of which runs as a single atomic PostgreSQL
# transaction inside the target Marine DB and only persists Chatwoot state AFTER
# the database COMMIT succeeds:
#
#   * downgrade_to_writer! — reassign objects owned by the login to the internal
#     NOLOGIN owner, DROP OWNED BY the login to strip every grant/default-ACL it
#     holds across ALL schemas, re-harden PUBLIC, pin the role's attributes to the
#     least-privilege set, then grant only CONNECT + USAGE(marine_ai) +
#     SELECT/INSERT/UPDATE/DELETE on current marine_ai tables (NO TRUNCATE / NO
#     CREATE). Verifies the login owns zero objects cluster-wide afterwards. Only
#     allowed from the admin/provisioner state.
#   * revoke_all! — reassign owned objects, DROP OWNED BY the login, pin attributes
#     and set NOLOGIN. Idempotent from any active privilege level. Never drops the
#     database, schema, tables, or data.
#
# All work runs under the shared advisory lock. Every identifier is quoted; every
# failure is sanitized. State transitions are guarded so a revoked NOLOGIN account
# can never be silently "downgraded" back to writer.
module Marine
  module Provisioning
    class PrivilegeService
      TARGET_SCHEMA = Config::PROJECTION_SCHEMA

      def initialize(actor_id: nil)
        @actor_id = actor_id
        @trace_id = SecureRandom.uuid
      end

      # Downgrade is only valid from the freshly-provisioned admin state. Trying to
      # downgrade a writer (already downgraded) or a revoked NOLOGIN account raises
      # InvalidPrivilegeTransitionError instead of silently re-granting login.
      def downgrade_to_writer!
        run('privilege.downgrade',
            allowed_from: [StateStore::PRIVILEGE_ADMIN],
            new_level: StateStore::PRIVILEGE_WRITER) do |db|
          ensure_owner_role!(db)
          ensure_target_schema!(db)
          reassign_owned(db)
          drop_owned(db)
          revoke_memberships(db)
          enforce_role_attributes(db, can_login: true)
          harden_public(db)
          grant_writer_privileges(db)
          verify_owns_nothing!(db)
        end
      end

      # Revoke is idempotent and allowed from any active privilege level.
      def revoke_all!
        run('privilege.revoke_all',
            allowed_from: [StateStore::PRIVILEGE_ADMIN, StateStore::PRIVILEGE_WRITER, StateStore::PRIVILEGE_REVOKED],
            new_level: StateStore::PRIVILEGE_REVOKED) do |db|
          ensure_owner_role!(db)
          reassign_owned(db)
          drop_owned(db)
          revoke_memberships(db)
          enforce_role_attributes(db, can_login: false)
          harden_public(db)
          verify_owns_nothing!(db)
        end
      end

      private

      # Concurrency-safe lifecycle step. The advisory lock is acquired FIRST; only then
      # do we re-read the current privilege level under the lock, validate the
      # transition, run the DDL in one PG transaction, and persist the new level — all
      # while still holding the lock. This prevents a stale concurrent action (whose
      # transition was validated against pre-lock state) from running after another
      # action already changed the level. The lock is released only afterwards.
      #
      # Cross-database atomicity limit: the target DDL lives in the Marine DB while the
      # durable level lives in Chatwoot's InstallationConfig — two databases that cannot
      # share one transaction. If the DDL COMMITs but the state write fails we do NOT
      # claim a rollback; we raise StateSyncError for manual reconciliation.
      def run(action, allowed_from:, new_level:)
        raise Errors::NotProvisionedError unless StateStore.provisioned?

        audit(action, 'started')
        Connection.with_admin_on(database_name) do |db|
          acquire_lock!(db)
          begin
            guard_transition!(allowed_from, locked_privilege_level)
            within_pg_transaction(db) { yield db }
            persist_level!(action, new_level)
          ensure
            release_lock(db)
          end
        end
        audit(action, 'succeeded')
        StateStore.current
      rescue Errors::SanitizedError => e
        audit(action, 'failed', detail: e.i18n_key)
        raise e
      rescue StandardError => e
        sanitized = ErrorSanitizer.sanitize(e, trace_id: @trace_id)
        audit(action, 'failed', detail: sanitized.i18n_key)
        raise sanitized
      end

      # Re-read the durable privilege level from the InstallationConfig UNDER the lock,
      # never from the pre-lock memo, so the transition is validated against the truth
      # at the moment we hold exclusive access.
      def locked_privilege_level
        StateStore.current['privilege_level']
      end

      def guard_transition!(allowed_from, current_level)
        return if allowed_from.include?(current_level)

        raise Errors::InvalidPrivilegeTransitionError
      end

      # Persist the new level while the advisory lock is still held. The DDL is already
      # committed at this point; if this write fails the database and state have
      # diverged, so surface StateSyncError (never a rollback claim) for reconciliation.
      def persist_level!(action, new_level)
        StateStore.write!(privilege_level: new_level)
      rescue Errors::SanitizedError
        raise
      rescue StandardError => e
        ErrorSanitizer.sanitize(e, trace_id: @trace_id)
        audit(action, 'state_sync_failed', detail: 'PROVISIONING.ERRORS.STATE_SYNC')
        raise Errors::StateSyncError
      end

      def within_pg_transaction(db)
        db.exec('BEGIN')
        begin
          result = yield db
          db.exec('COMMIT')
          result
        rescue StandardError
          safe_rollback(db)
          raise
        end
      end

      def safe_rollback(db)
        db.exec('ROLLBACK')
      rescue StandardError
        nil
      end

      # The internal owner must still exist and remain fully least-privilege before we
      # reassign ownership to it; otherwise a downgrade could transfer objects to a role
      # that can log in or escalate, defeating the point of the separation. We fail
      # closed if ANY dangerous attribute was altered onto the owner out-of-band.
      def ensure_owner_role!(db)
        row = db.exec_params(<<~SQL, [owner_role]).first
          SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls
          FROM pg_roles WHERE rolname = $1
        SQL
        raise owner_role_error('Owner role is not available') if row.nil?
        raise owner_role_error('Owner role must not be able to log in') if truthy?(row['rolcanlogin'])

        dangerous = %w[rolsuper rolcreatedb rolcreaterole rolreplication rolbypassrls]
        return unless dangerous.any? { |attr| truthy?(row[attr]) }

        raise owner_role_error('Owner role must not hold elevated attributes')
      end

      def owner_role_error(message)
        Errors::SanitizedError.new(message, i18n_key: 'PROVISIONING.ERRORS.OWNER_ROLE_INVALID')
      end

      def ensure_target_schema!(db)
        return if schema_present?(db)

        raise Errors::SanitizedError.new('Target schema is not available', i18n_key: 'PROVISIONING.ERRORS.SCHEMA_MISSING')
      end

      def schema_present?(db)
        db.exec_params('SELECT 1 FROM information_schema.schemata WHERE schema_name = $1', [TARGET_SCHEMA]).ntuples.positive?
      end

      # Transfer ownership of every object the login owns in this DB to the internal
      # owner. Must run BEFORE drop_owned so drop_owned removes only grants, never data.
      def reassign_owned(db)
        db.exec("REASSIGN OWNED BY #{db.quote_ident(login)} TO #{db.quote_ident(owner_role)}")
      end

      # After REASSIGN OWNED transferred ownership away, DROP OWNED BY the login
      # removes every remaining privilege and default-ACL the login
      # holds across ALL schemas in this database (not just marine_ai/public).
      # Because the login now owns nothing, no objects are dropped — only grants.
      def drop_owned(db)
        db.exec("DROP OWNED BY #{db.quote_ident(login)}")
      end

      # DROP OWNED does NOT revoke role memberships granted TO the login. Any residual
      # membership could hand the login another role's privileges, so we explicitly
      # query pg_auth_members for every role the login is a member of and REVOKE each,
      # inside the same transaction. Runs in both downgrade and revoke.
      def revoke_memberships(db)
        rows = db.exec_params(<<~SQL, [login])
          SELECT g.rolname AS granted_role
          FROM pg_auth_members m
          JOIN pg_roles g ON g.oid = m.roleid
          JOIN pg_roles member ON member.oid = m.member
          WHERE member.rolname = $1
        SQL
        rows.each do |row|
          db.exec("REVOKE #{db.quote_ident(row['granted_role'])} FROM #{db.quote_ident(login)}")
        end
      end

      # Pin the role to the least-privilege attribute set every time. The only thing
      # that varies is whether it may log in (writer keeps LOGIN, revoke sets NOLOGIN).
      def enforce_role_attributes(db, can_login:)
        login_clause = can_login ? 'LOGIN' : 'NOLOGIN'
        db.exec(
          "ALTER ROLE #{db.quote_ident(login)} #{login_clause} " \
          'NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS'
        )
      end

      # Re-assert least privilege for PUBLIC after DROP OWNED, so neither action can
      # leave PUBLIC able to connect, create temp objects, or use the public schema.
      def harden_public(db)
        db.exec("REVOKE CONNECT, TEMPORARY ON DATABASE #{db.quote_ident(database_name)} FROM PUBLIC")
        db.exec('REVOKE ALL ON SCHEMA public FROM PUBLIC')
      end

      # Writer = read/write DML only. Explicitly excludes TRUNCATE and CREATE, and
      # grants NO function/procedure or sequence privileges. Because PostgreSQL grants
      # EXECUTE on functions/procedures to PUBLIC by default, the writer would otherwise
      # inherit execute rights on ERP-created routines through PUBLIC — so we strip that
      # PUBLIC execute BEFORE issuing the writer grants.
      def grant_writer_privileges(db)
        revoke_public_function_execution(db)
        db.exec("GRANT CONNECT ON DATABASE #{db.quote_ident(database_name)} TO #{db.quote_ident(login)}")
        db.exec("GRANT USAGE ON SCHEMA #{db.quote_ident(TARGET_SCHEMA)} TO #{db.quote_ident(login)}")
        db.exec(
          "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{db.quote_ident(TARGET_SCHEMA)} " \
          "TO #{db.quote_ident(login)}"
        )
      end

      # Remove the default PUBLIC EXECUTE on every function and procedure in the
      # projection schema so the writer cannot retain execute capability via PUBLIC.
      def revoke_public_function_execution(db)
        db.exec("REVOKE ALL ON ALL FUNCTIONS IN SCHEMA #{db.quote_ident(TARGET_SCHEMA)} FROM PUBLIC")
        db.exec("REVOKE ALL ON ALL PROCEDURES IN SCHEMA #{db.quote_ident(TARGET_SCHEMA)} FROM PUBLIC")
      end

      # Comprehensive ownership check: catalogs for the common object classes PLUS
      # pg_shdepend owner rows (deptype 'o') scoped to shared objects (dbid 0) and
      # this database, so nothing owned by the login survives the transition.
      def verify_owns_nothing!(db)
        count = db.exec_params(<<~SQL, [login]).getvalue(0, 0).to_i
          SELECT
            (SELECT count(*) FROM pg_class     c WHERE c.relowner = r.oid) +
            (SELECT count(*) FROM pg_namespace n WHERE n.nspowner = r.oid) +
            (SELECT count(*) FROM pg_proc      p WHERE p.proowner = r.oid) +
            (SELECT count(*) FROM pg_type      t WHERE t.typowner = r.oid) +
            (SELECT count(*) FROM pg_database  d WHERE d.datdba   = r.oid) +
            (SELECT count(*) FROM pg_shdepend  s
               WHERE s.refobjid = r.oid AND s.deptype = 'o'
                 AND s.dbid IN (0, (SELECT oid FROM pg_database WHERE datname = current_database())))
          FROM pg_roles r WHERE r.rolname = $1
        SQL
        return if count.zero?

        raise Errors::SanitizedError.new('Login still owns objects after downgrade', i18n_key: 'PROVISIONING.ERRORS.DOWNGRADE_INCOMPLETE')
      end

      def acquire_lock!(db)
        locked = db.exec_params('SELECT pg_try_advisory_lock($1)', [ProvisionService::ADVISORY_LOCK_KEY]).getvalue(0, 0)
        raise Errors::LockUnavailableError unless truthy?(locked)
      end

      def release_lock(db)
        db.exec_params('SELECT pg_advisory_unlock($1)', [ProvisionService::ADVISORY_LOCK_KEY])
      rescue StandardError
        nil
      end

      def state
        @state ||= StateStore.current
      end

      def database_name = state['database_name']
      def login = state['login_username']
      def owner_role = state['owner_role']

      def audit(action, result, detail: nil)
        Audit.record(
          action: action, actor_id: @actor_id, result: result, trace_id: @trace_id, detail: detail,
          target: { database_name: database_name, login_username: login, owner_role: owner_role }
        )
      end

      def truthy?(value)
        %w[t true 1].include?(value.to_s.downcase)
      end
    end
  end
end
