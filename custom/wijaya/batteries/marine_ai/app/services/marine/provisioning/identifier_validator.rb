# Strict, PostgreSQL-safe validation for admin-supplied identifiers (database name,
# login role name, owner role name). Admin input is never interpolated into SQL
# without both passing this validator AND being quoted with quote_ident at the
# call site. This is defense-in-depth against injection and reserved-name misuse.
module Marine
  module Provisioning
    module IdentifierValidator
      MAX_BYTES = 63
      # lowercase start (letter/underscore), then letters/digits/underscore. We reject
      # anything requiring quoting to avoid casing/collision surprises across the app.
      PATTERN = /\A[a-z_][a-z0-9_]*\z/

      # A conservative subset of reserved / system-ish names we refuse outright.
      RESERVED = %w[
        postgres template0 template1 public pg_catalog pg_toast information_schema
        current_user session_user user current_database admin root superuser
        pg_database_owner
      ].freeze
      RESERVED_PREFIX = 'pg_'.freeze

      module_function

      # Returns the validated identifier or raises InvalidIdentifierError. `extra_reserved`
      # lets callers add runtime-forbidden names (e.g. the current Chatwoot DB/role).
      def validate!(value, label:, extra_reserved: [])
        name = value.to_s
        raise invalid(label, 'must be present') if name.strip.empty?
        raise invalid(label, 'is too long') if name.bytesize > MAX_BYTES
        raise invalid(label, 'has an invalid format') unless PATTERN.match?(name)
        raise invalid(label, 'is reserved') if reserved?(name, extra_reserved)

        name
      end

      def valid?(value, extra_reserved: [])
        validate!(value, label: 'identifier', extra_reserved: extra_reserved)
        true
      rescue Errors::InvalidIdentifierError
        false
      end

      def reserved?(name, extra_reserved)
        lowered = name.downcase
        return true if lowered.start_with?(RESERVED_PREFIX)
        return true if RESERVED.include?(lowered)

        extra_reserved.compact.map(&:to_s).map(&:downcase).include?(lowered)
      end

      def invalid(label, reason)
        # Message is safe to surface: it contains only the field label and a generic
        # reason, never the raw value.
        Errors::InvalidIdentifierError.new("#{label} #{reason}")
      end
    end
  end
end
