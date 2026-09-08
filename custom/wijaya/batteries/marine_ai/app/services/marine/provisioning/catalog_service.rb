# Read-only privilege inspector for the "Show Current Privileges" button. Queries
# PostgreSQL catalogs directly (has_*_privilege + pg_roles/pg_class/pg_stat_ssl)
# and returns a structured matrix only. It NEVER returns the password, a connection
# string, raw ACL arrays, or SQL text. This performs no state change.
#
# The matrix intentionally distinguishes, per table privilege, whether the login
# holds it on ALL tables vs ANY table (plus a total table count), because a bare
# bool_or would misleadingly report "has SELECT" when only one of many tables is
# readable. It also reports whether the login can CONNECT to the existing Chatwoot
# database — which must always be false.
module Marine
  module Provisioning
    class CatalogService # rubocop:disable Metrics/ClassLength
      TARGET_SCHEMA = PrivilegeService::TARGET_SCHEMA

      def initialize(actor_id: nil)
        @actor_id = actor_id
        @trace_id = SecureRandom.uuid
      end

      def call
        raise Errors::NotProvisionedError unless StateStore.provisioned?

        audit('started')
        matrix = Connection.with_admin_on(database_name) { |db| build_matrix(db) }
        audit('succeeded')
        matrix
      rescue Errors::SanitizedError => e
        audit('failed', detail: e.i18n_key)
        raise e
      rescue StandardError => e
        sanitized = ErrorSanitizer.sanitize(e, trace_id: @trace_id)
        audit('failed', detail: sanitized.i18n_key)
        raise sanitized
      end

      private

      def build_matrix(db)
        {
          login_username: login,
          privilege_level: state['privilege_level'],
          role: role_attributes(db),
          memberships: role_memberships(db),
          database: database_privileges(db),
          schemas: schema_privileges(db),
          tables: table_privileges(db),
          functions: function_privileges(db),
          sequences: sequence_privileges(db),
          owned_objects: owned_object_count(db),
          ssl: ssl_status(db)
        }
      end

      # Roles granted TO the login. After downgrade/revoke this must be empty — a
      # lingering membership could hand the login another role's privileges.
      def role_memberships(db)
        rows = db.exec_params(<<~SQL.squish, [login])
          SELECT g.rolname AS granted_role
          FROM pg_auth_members m
          JOIN pg_roles g ON g.oid = m.roleid
          JOIN pg_roles member ON member.oid = m.member
          WHERE member.rolname = $1
          ORDER BY g.rolname
        SQL
        names = rows.pluck('granted_role')
        { count: names.length, roles: names }
      end

      # Full attribute set so the UI can flag any dangerous grant (createrole,
      # createdb, replication, bypassrls) as well as login/superuser.
      def role_attributes(db)
        row = db.exec_params(<<~SQL.squish, [login]).first || {}
          SELECT rolcanlogin, rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls
          FROM pg_roles WHERE rolname = $1
        SQL
        {
          can_login: truthy?(row['rolcanlogin']),
          superuser: truthy?(row['rolsuper']),
          create_role: truthy?(row['rolcreaterole']),
          create_db: truthy?(row['rolcreatedb']),
          replication: truthy?(row['rolreplication']),
          bypass_rls: truthy?(row['rolbypassrls'])
        }
      end

      def database_privileges(db)
        row = db.exec_params(<<~SQL.squish, [login, database_name]).first
          SELECT has_database_privilege($1, $2, 'CONNECT') AS connect,
                 has_database_privilege($1, $2, 'CREATE') AS create,
                 has_database_privilege($1, $2, 'TEMPORARY') AS temporary
        SQL
        chatwoot = chatwoot_connect(db)
        {
          name: database_name,
          connect: truthy?(row['connect']),
          create: truthy?(row['create']),
          temporary: truthy?(row['temporary']),
          # nil when the check itself could not run (see chatwoot_connect); never
          # coerced to a boolean so an operator is not falsely reassured OR alarmed.
          chatwoot_connect: chatwoot[:value],
          chatwoot_connect_check_error: chatwoot[:check_error]
        }
      end

      # Whether the login can CONNECT to the existing Chatwoot DB. Must be false. If
      # the check itself fails we return an explicit unknown (value: nil, check_error:
      # true) rather than a fabricated boolean, so a catalog error is never surfaced as
      # a security value. The API/UI can then fail closed on its own terms.
      def chatwoot_connect(db)
        chatwoot = Config.app_database
        return { value: false, check_error: false } if chatwoot.blank?

        row = db.exec_params('SELECT has_database_privilege($1, $2, $3) AS connect', [login, chatwoot, 'CONNECT']).first
        { value: truthy?(row['connect']), check_error: false }
      rescue StandardError
        { value: nil, check_error: true }
      end

      def schema_privileges(db)
        [TARGET_SCHEMA, 'public'].map do |schema|
          next { name: schema, present: false, usage: false, create: false } unless schema_present?(db, schema)

          row = db.exec_params(<<~SQL.squish, [login, schema]).first
            SELECT has_schema_privilege($1, $2, 'USAGE') AS usage,
                   has_schema_privilege($1, $2, 'CREATE') AS create
          SQL
          { name: schema, present: true, usage: truthy?(row['usage']), create: truthy?(row['create']) }
        end
      end

      # Per privilege, report coverage across ALL vs ANY marine_ai tables plus the
      # total table count. bool_and/bool_or over zero tables is NULL, coalesced to
      # false so "no tables" reads as no coverage rather than vacuous truth.
      def table_privileges(db) # rubocop:disable Metrics/MethodLength
        row = db.exec_params(<<~SQL.squish, [login, TARGET_SCHEMA]).first
          SELECT
            count(*)                                                             AS total,
            COALESCE(bool_and(has_table_privilege($1, c.oid, 'SELECT')), false)   AS select_all,
            COALESCE(bool_or(has_table_privilege($1, c.oid, 'SELECT')), false)    AS select_any,
            COALESCE(bool_and(has_table_privilege($1, c.oid, 'INSERT')), false)   AS insert_all,
            COALESCE(bool_or(has_table_privilege($1, c.oid, 'INSERT')), false)    AS insert_any,
            COALESCE(bool_and(has_table_privilege($1, c.oid, 'UPDATE')), false)   AS update_all,
            COALESCE(bool_or(has_table_privilege($1, c.oid, 'UPDATE')), false)    AS update_any,
            COALESCE(bool_and(has_table_privilege($1, c.oid, 'DELETE')), false)   AS delete_all,
            COALESCE(bool_or(has_table_privilege($1, c.oid, 'DELETE')), false)    AS delete_any,
            COALESCE(bool_or(has_table_privilege($1, c.oid, 'TRUNCATE')), false)  AS truncate_any
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = $2 AND c.relkind IN ('r', 'p')
        SQL
        {
          schema: TARGET_SCHEMA,
          total: row['total'].to_i,
          select: { all: truthy?(row['select_all']), any: truthy?(row['select_any']) },
          insert: { all: truthy?(row['insert_all']), any: truthy?(row['insert_any']) },
          update: { all: truthy?(row['update_all']), any: truthy?(row['update_any']) },
          delete: { all: truthy?(row['delete_all']), any: truthy?(row['delete_any']) },
          truncate: { any: truthy?(row['truncate_any']) }
        }
      end

      # Effective function/procedure EXECUTE coverage for the login across the
      # projection schema. For an exact writer this must be zero — the writer holds NO
      # function privileges, and PUBLIC execute is stripped during downgrade.
      def function_privileges(db)
        row = db.exec_params(<<~SQL.squish, [login, TARGET_SCHEMA]).first
          SELECT count(*) AS total,
                 COALESCE(bool_or(has_function_privilege($1, p.oid, 'EXECUTE')), false) AS execute_any
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = $2
        SQL
        { schema: TARGET_SCHEMA, total: row['total'].to_i, execute_any: truthy?(row['execute_any']) }
      end

      # Effective sequence privilege coverage for the login. An exact writer holds NO
      # sequence privileges (no USAGE/SELECT/UPDATE), so every "any" flag must be false.
      def sequence_privileges(db)
        row = db.exec_params(<<~SQL.squish, [login, TARGET_SCHEMA]).first
          SELECT count(*) AS total,
                 COALESCE(bool_or(has_sequence_privilege($1, c.oid, 'USAGE')), false)  AS usage_any,
                 COALESCE(bool_or(has_sequence_privilege($1, c.oid, 'SELECT')), false) AS select_any,
                 COALESCE(bool_or(has_sequence_privilege($1, c.oid, 'UPDATE')), false) AS update_any
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = $2 AND c.relkind = 'S'
        SQL
        {
          schema: TARGET_SCHEMA,
          total: row['total'].to_i,
          usage_any: truthy?(row['usage_any']),
          select_any: truthy?(row['select_any']),
          update_any: truthy?(row['update_any'])
        }
      end

      # Comprehensive ownership count, matching the lifecycle verification: relations,
      # schemas, functions, types, databases owned by the login PLUS pg_shdepend owner
      # rows (deptype 'o') for shared and current-database objects. A bare
      # pg_class+pg_namespace count would miss functions/types and shared dependencies.
      def owned_object_count(db)
        db.exec_params(<<~SQL.squish, [login]).getvalue(0, 0).to_i
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
      end

      # Effective SSL for this provisioning session from pg_stat_ssl, falling back to
      # the configured sslmode when the view is unavailable.
      def ssl_status(db)
        row = db.exec('SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()').first
        { in_use: truthy?(row && row['ssl']), configured_mode: Config.ssl_mode }
      rescue StandardError
        { in_use: nil, configured_mode: Config.ssl_mode }
      end

      def schema_present?(db, schema)
        db.exec_params('SELECT 1 FROM information_schema.schemata WHERE schema_name = $1', [schema]).ntuples.positive?
      end

      def state
        @state ||= StateStore.current
      end

      def database_name = state['database_name']
      def login = state['login_username']

      def audit(result, detail: nil)
        Audit.record(action: 'privilege.show', actor_id: @actor_id, result: result, trace_id: @trace_id, detail: detail,
                     target: { login_username: login })
      end

      def truthy?(value)
        %w[t true 1].include?(value.to_s.downcase)
      end
    end
  end
end
