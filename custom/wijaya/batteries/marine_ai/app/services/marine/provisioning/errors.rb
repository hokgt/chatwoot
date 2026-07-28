# Error hierarchy for Marine provisioning. Every error surfaced to the API/UI must
# be a SanitizedError so the controller can render a safe, human-readable message
# without leaking SQL, connection strings, PG internals, or secrets.
module Marine
  module Provisioning
    module Errors
      # Base for anything safe to show a user. `i18n_key` lets the frontend localize.
      class SanitizedError < StandardError
        attr_reader :i18n_key

        def initialize(message, i18n_key: nil)
          @i18n_key = i18n_key
          super(message)
        end
      end

      # Bootstrap/superuser credential (Docker secret) is missing or unreadable.
      # Fail closed with this — never expose why beyond "unavailable".
      class CredentialUnavailableError < SanitizedError
        def initialize(message = 'Provisioning credential unavailable')
          super(message, i18n_key: 'PROVISIONING.ERRORS.CREDENTIAL_UNAVAILABLE')
        end
      end

      # Admin-supplied identifier failed strict PostgreSQL-safe validation.
      class InvalidIdentifierError < SanitizedError
        def initialize(message = 'Invalid identifier', i18n_key: 'PROVISIONING.ERRORS.INVALID_IDENTIFIER')
          super
        end
      end

      # Database/account already provisioned; creation may happen only once.
      class AlreadyProvisionedError < SanitizedError
        def initialize(message = 'Marine database is already provisioned')
          super(message, i18n_key: 'PROVISIONING.ERRORS.ALREADY_PROVISIONED')
        end
      end

      # Provisioning not yet run — privilege actions require an existing login.
      class NotProvisionedError < SanitizedError
        def initialize(message = 'Marine database is not provisioned yet')
          super(message, i18n_key: 'PROVISIONING.ERRORS.NOT_PROVISIONED')
        end
      end

      # Another provisioning action holds the advisory lock.
      class LockUnavailableError < SanitizedError
        def initialize(message = 'Another provisioning action is in progress')
          super(message, i18n_key: 'PROVISIONING.ERRORS.LOCK_UNAVAILABLE')
        end
      end

      # A staged step failed; compensation succeeded and nothing was marked ready.
      class ProvisioningFailedError < SanitizedError
        def initialize(message = 'Provisioning failed and was rolled back')
          super(message, i18n_key: 'PROVISIONING.ERRORS.FAILED')
        end
      end

      # A staged step failed AND compensation failed — manual cleanup required.
      class ManualCleanupRequiredError < SanitizedError
        def initialize(message = 'Provisioning failed and requires manual cleanup')
          super(message, i18n_key: 'PROVISIONING.ERRORS.NEEDS_MANUAL_CLEANUP')
        end
      end

      # A privilege change was requested from a state that does not permit it (for
      # example, downgrading a revoked NOLOGIN account back to writer).
      class InvalidPrivilegeTransitionError < SanitizedError
        def initialize(message = 'This privilege change is not allowed from the current state')
          super(message, i18n_key: 'PROVISIONING.ERRORS.INVALID_TRANSITION')
        end
      end

      # The target PostgreSQL transaction COMMITted successfully but persisting the new
      # privilege level to durable Chatwoot state failed. The database change is NOT
      # rolled back (it is already committed); this signals a state/DB divergence that
      # needs manual reconciliation. Never claim a rollback for this case.
      class StateSyncError < SanitizedError
        def initialize(message = 'The privilege change was applied but its state could not be recorded; manual reconciliation required')
          super(message, i18n_key: 'PROVISIONING.ERRORS.STATE_SYNC')
        end
      end
    end
  end
end
