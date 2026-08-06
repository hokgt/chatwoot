# Durable, installation-level, NON-SECRET provisioning state. Backed by a single
# InstallationConfig row (jsonb serialized_value). InstallationConfig is NOT
# encrypted, so this MUST never contain the login password, the bootstrap password,
# a connection string, or any secret — only descriptive metadata.
module Marine
  module Provisioning
    module StateStore
      CONFIG_NAME = 'MARINE_PROVISIONING_STATE'.freeze

      STATUS_NOT_PROVISIONED = 'not_provisioned'.freeze
      STATUS_ACTIVE = 'active'.freeze
      STATUS_NEEDS_MANUAL_CLEANUP = 'needs_manual_cleanup'.freeze

      PRIVILEGE_ADMIN = 'admin'.freeze
      PRIVILEGE_WRITER = 'writer'.freeze
      PRIVILEGE_REVOKED = 'revoked'.freeze

      # Whitelist of keys allowed to persist. Guards against a caller accidentally
      # stashing a secret in the state blob.
      ALLOWED_KEYS = %w[
        status database_name login_username owner_role host port ssl_mode
        schema privilege_level provisioned_at cleanup_note updated_at
      ].freeze

      module_function

      def current
        raw = InstallationConfig.find_by(name: CONFIG_NAME)&.value
        base = { 'status' => STATUS_NOT_PROVISIONED }
        return base if raw.blank?

        base.merge(raw.to_h.slice(*ALLOWED_KEYS))
      end

      def provisioned?
        current['status'] == STATUS_ACTIVE
      end

      def exists?
        %w[active needs_manual_cleanup].include?(current['status'])
      end

      def write!(attrs)
        sanitized = attrs.stringify_keys.slice(*ALLOWED_KEYS)
        sanitized['updated_at'] = Time.current.iso8601
        config = InstallationConfig.where(name: CONFIG_NAME).first_or_initialize
        config.value = current.merge(sanitized)
        config.locked = false
        config.save!
        config.value
      end

      def reset!
        InstallationConfig.where(name: CONFIG_NAME).destroy_all
      end
    end
  end
end
