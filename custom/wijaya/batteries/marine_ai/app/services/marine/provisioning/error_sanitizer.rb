# Maps low-level PostgreSQL / internal failures onto safe, human-readable messages.
# The API must NEVER return raw PG errors, SQLSTATE payloads, SQL text, stack
# traces, connection strings, or secrets. Everything funnels through here so the
# controller only ever sees a SanitizedError.
module Marine
  module Provisioning
    module ErrorSanitizer
      # SQLSTATE class/code -> [i18n_key, human message]
      SQLSTATE_MAP = {
        '42501' => ['PROVISIONING.ERRORS.INSUFFICIENT_PRIVILEGE', 'The provisioning credential lacks the required privileges'],
        '42P04' => ['PROVISIONING.ERRORS.DB_EXISTS', 'A database with that name already exists'],
        '42710' => ['PROVISIONING.ERRORS.ROLE_EXISTS', 'A role with that name already exists'],
        '28P01' => ['PROVISIONING.ERRORS.AUTH_FAILED', 'The provisioning credential was rejected'],
        '3D000' => ['PROVISIONING.ERRORS.DB_MISSING', 'The target database does not exist'],
        '55006' => ['PROVISIONING.ERRORS.OBJECT_IN_USE', 'The target object is in use; try again shortly'],
        '57014' => ['PROVISIONING.ERRORS.TIMEOUT', 'The database took too long to respond'],
        '53300' => ['PROVISIONING.ERRORS.TOO_MANY_CONNECTIONS', 'The database has too many connections; try again shortly']
      }.freeze

      GENERIC = ['PROVISIONING.ERRORS.GENERIC', 'The provisioning request could not be completed'].freeze

      module_function

      # Returns a SanitizedError for any raised error, logging the real cause under a
      # trace id so operators can debug without leaking anything to the client.
      def sanitize(error, trace_id: nil)
        return error if error.is_a?(Errors::SanitizedError)

        key, message = lookup(error)
        log_internal(error, trace_id, key)
        Errors::SanitizedError.new(message, i18n_key: key)
      end

      def lookup(error)
        sqlstate = sqlstate_for(error)
        return SQLSTATE_MAP[sqlstate] if sqlstate && SQLSTATE_MAP.key?(sqlstate)

        GENERIC
      end

      def sqlstate_for(error)
        return unless error.respond_to?(:result) && error.result

        error.result.error_field(PG::PG_DIAG_SQLSTATE)
      rescue StandardError
        nil
      end

      # We log the class name and SQLSTATE only — never error.message, which for PG
      # can echo the offending SQL (and thus a password literal).
      def log_internal(error, trace_id, key)
        Rails.logger.error(
          {
            tag: 'marine.provisioning.error',
            trace_id: trace_id,
            error_class: error.class.name,
            sqlstate: sqlstate_for(error),
            mapped_key: key
          }.compact.to_json
        )
      end
    end
  end
end
