# frozen_string_literal: true

require 'uri'

# Fail-safe isolation for the RAILS_ENV=test database.
#
# Incident background: `docker compose run ... -e RAILS_ENV=test base ...`
# inherited POSTGRES_DATABASE=chatwoot_production from the Compose env_file, so
# test tasks migrated / attempted db:test:purge against production. PostgreSQL
# blocked the purge, but test isolation must now be fail-closed.
#
# This battery is pure Ruby with NO database connection. It is invoked from the
# smallest possible hook in config/database.yml (the test: section) so it runs
# before ActiveRecord ever connects. In the test environment it:
#   * ignores the generic POSTGRES_DATABASE for test DB selection,
#   * uses POSTGRES_TEST_DATABASE (default chatwoot_test),
#   * rejects any name/URL that is not clearly test-only,
#   * neutralizes a generic DATABASE_URL so it cannot silently win, and
#   * fails closed with a sanitized message and a nonzero exit.
#
# It never alters production/development database selection: outside the test
# environment resolve! is a no-op that returns the historical default.
module Wijaya
  module Batteries
    module TestDatabaseSafety
      # Raised by the pure resolver when the requested test database is unsafe.
      # The message is always sanitized: it contains only a field label, a generic
      # reason, and (at most) a scrubbed database name -- never a URL, host,
      # username, or password.
      class UnsafeTestDatabaseError < StandardError; end

      module Guard
        DEFAULT_TEST_DATABASE = 'chatwoot_test'

        # A clearly test-only name is a lowercase PostgreSQL-safe identifier that
        # contains "test" and none of the production-ish markers below.
        SAFE_NAME_PATTERN = /\A[a-z_][a-z0-9_]*\z/

        # Substrings that mark a name as NON-test even if it also contains "test"
        # (e.g. "production_test_restore"). Fail closed on ambiguity.
        FORBIDDEN_SUBSTRINGS = %w[prod production live staging].freeze

        # Explicit production / system databases we refuse outright.
        FORBIDDEN_NAMES = %w[chatwoot_production chatwoot postgres template0 template1].freeze

        # Only PostgreSQL connection URLs are ever accepted.
        ALLOWED_URL_SCHEMES = %w[postgres postgresql].freeze

        module_function

        # Effective environment WITHOUT booting Rails (database.yml is ERB-rendered
        # for every environment, so this must be cheap and side-effect free).
        def effective_env(env = ENV)
          rails_env = defined?(Rails) && Rails.respond_to?(:env) && Rails.env ? Rails.env.to_s : nil
          (env['RAILS_ENV'] || env['RACK_ENV'] || rails_env || 'development').to_s
        end

        def test_env?(env = ENV)
          effective_env(env) == 'test'
        end

        # Structural + semantic definition of "clearly test-only".
        def test_only?(name)
          candidate = name.to_s
          return false unless SAFE_NAME_PATTERN.match?(candidate)

          lowered = candidate.downcase
          return false if FORBIDDEN_NAMES.include?(lowered)
          return false if FORBIDDEN_SUBSTRINGS.any? { |marker| lowered.include?(marker) }

          lowered.include?('test')
        end

        # Pure resolver. Returns the safe test database name or raises
        # UnsafeTestDatabaseError. Performs NO database connection and NO process
        # exit, so it is fully unit-testable. `env` is any Hash-like (defaults to
        # the real ENV).
        def safe_test_database_name(env = ENV) # rubocop:disable Metrics/CyclomaticComplexity
          # 1. Preferred explicit test URL. Still validated.
          return database_name_from_url!(env['TEST_DATABASE_URL'], label: 'TEST_DATABASE_URL') if present?(env['TEST_DATABASE_URL'])

          # 2. A generic DATABASE_URL must never silently win in test. Accept only
          #    when it clearly points at a test-only database; otherwise reject.
          return database_name_from_url!(env['DATABASE_URL'], label: 'DATABASE_URL') if present?(env['DATABASE_URL'])

          # 3. Name-based selection. Ignore generic POSTGRES_DATABASE for the test
          #    database; use POSTGRES_TEST_DATABASE (default chatwoot_test).
          name = present?(env['POSTGRES_TEST_DATABASE']) ? env['POSTGRES_TEST_DATABASE'].to_s : DEFAULT_TEST_DATABASE
          generic = env['POSTGRES_DATABASE'].to_s

          # Explicitly reject equality with a non-test generic value (defense in
          # depth against a leaked production POSTGRES_DATABASE being reused).
          if present?(generic) && name == generic && !test_only?(generic)
            raise unsafe("POSTGRES_TEST_DATABASE must not equal the non-test POSTGRES_DATABASE value #{sanitize(generic)}")
          end

          raise unsafe("POSTGRES_TEST_DATABASE #{sanitize(name)} is not a clearly test-only database name") unless test_only?(name)

          name
        end

        # Parse a database name out of a connection URL and validate the scheme is
        # PostgreSQL and the database is test-only. Never echoes the URL, host, or
        # credentials.
        def database_name_from_url!(url, label:)
          parsed = begin
            URI.parse(url.to_s)
          rescue URI::InvalidURIError
            nil
          end

          raise unsafe("#{label} is malformed or is missing a database name") if parsed.nil?
          raise unsafe("#{label} must use a postgres:// or postgresql:// scheme") unless ALLOWED_URL_SCHEMES.include?(parsed.scheme.to_s.downcase)

          database = parsed.path.to_s.delete_prefix('/')
          raise unsafe("#{label} is malformed or is missing a database name") if database.empty?
          raise unsafe("#{label} database #{sanitize(database)} is not a clearly test-only database name") unless test_only?(database)

          database
        end

        # Entry point for config/database.yml. Fail-closed: only enforces in the
        # test environment. Returns the safe database name and configures the
        # effective connection source in ENV (see apply_connection_source!). On
        # unsafe configuration it prints a sanitized refusal and exits nonzero
        # BEFORE ActiveRecord connects. Outside test it returns the historical
        # default and touches nothing (production/development selection unaffected).
        def resolve!(env = ENV)
          return DEFAULT_TEST_DATABASE unless test_env?(env)

          name = safe_test_database_name(env)
          apply_connection_source!(env)
          name
        rescue UnsafeTestDatabaseError => e
          warn "[wijaya:test_database_safety] REFUSED: #{e.message}"
          warn '[wijaya:test_database_safety] Refusing to run RAILS_ENV=test against a non-test database. ' \
               'Set POSTGRES_TEST_DATABASE to a clearly test-only name (default chatwoot_test), ' \
               'clear the generic DATABASE_URL, or use a test-only TEST_DATABASE_URL.'
          exit(1)
        end

        # Configure the effective test connection in ENV, mirroring the (already
        # validated) source that safe_test_database_name selected. Only runs after
        # validation succeeded, so any URL touched here is a proven test-only URL.
        #   * TEST_DATABASE_URL  -> promote it to DATABASE_URL so ActiveRecord uses
        #                           its host/credentials/database (URL wins over yml).
        #   * generic DATABASE_URL (validated safe) -> leave it in place.
        #   * name-based selection -> clear any generic DATABASE_URL so it cannot
        #                             silently override the validated name/host.
        def apply_connection_source!(env)
          return unless env.respond_to?(:[]=) && env.respond_to?(:delete)

          if present?(env['TEST_DATABASE_URL'])
            env['DATABASE_URL'] = env['TEST_DATABASE_URL'].to_s
          elsif present?(env['DATABASE_URL'])
            # Validated safe: use it as-is.
          else
            env.delete('DATABASE_URL')
          end
        end

        def present?(value)
          !value.nil? && !value.to_s.strip.empty?
        end

        # Scrub a database name for display: only [a-z0-9_] survive, capped at the
        # PostgreSQL identifier length. Guarantees no credentials/URL leak into logs.
        def sanitize(name)
          name.to_s.downcase.gsub(/[^a-z0-9_]/, '?')[0, 63].to_s
        end

        def unsafe(message)
          UnsafeTestDatabaseError.new(message)
        end
      end
    end
  end
end
