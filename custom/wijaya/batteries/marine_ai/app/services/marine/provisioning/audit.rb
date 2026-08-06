# Structured audit log for every provisioning action. Records actor, action,
# target, result, timestamp, and a trace id. It NEVER records passwords,
# connection strings, raw SQL, or exception details — only sanitized labels.
module Marine
  module Provisioning
    class Audit
      def self.record(**kwargs)
        new(**kwargs).write!
      end

      def initialize(action:, actor_id: nil, target: nil, result: 'started', trace_id: nil, detail: nil)
        @action = action
        @actor_id = actor_id
        @target = target
        @result = result
        @trace_id = trace_id || SecureRandom.uuid
        @detail = detail
      end

      attr_reader :trace_id

      # Fixed placeholder emitted in place of any value that is not a bounded, strict,
      # trusted token. An untrusted value is NEVER logged raw or truncated.
      INVALID_VALUE_MARKER = '[invalid]'.freeze
      IDENTIFIER_KEYS = %i[database_name login_username owner_role].freeze
      ALLOWED_STATUSES = [
        StateStore::STATUS_NOT_PROVISIONED,
        StateStore::STATUS_ACTIVE,
        StateStore::STATUS_NEEDS_MANUAL_CLEANUP
      ].freeze
      ALLOWED_PRIVILEGE_LEVELS = [
        StateStore::PRIVILEGE_ADMIN,
        StateStore::PRIVILEGE_WRITER,
        StateStore::PRIVILEGE_REVOKED
      ].freeze

      def write!
        Rails.logger.info(log_line)
        trace_id
      end

      private

      def log_line
        {
          tag: 'marine.provisioning.audit',
          trace_id: @trace_id,
          actor_id: @actor_id,
          action: @action,
          target: sanitized_target,
          result: @result,
          detail: sanitized_detail,
          at: Time.current.iso8601
        }.compact.to_json
      end

      # Only allow a small set of non-secret, structured descriptive fields through,
      # AND sanitize their VALUES — whitelisting keys alone would still let an invalid
      # attacker-controlled database/login string (e.g. logged on a validation failure)
      # reach the log. A raw String target is rejected (rendered nil) so a caller can
      # never smuggle an arbitrary value in as the target, and any value that is not a
      # bounded strict identifier / known status / known privilege level is replaced
      # with a fixed marker — never logged or truncated raw.
      def sanitized_target
        return nil unless @target.respond_to?(:to_h)

        whitelisted = @target.to_h.symbolize_keys.slice(:database_name, :login_username, :owner_role, :privilege_level, :status)
        cleaned = whitelisted.each_with_object({}) do |(key, value), acc|
          next if value.nil?

          acc[key] = sanitized_target_value(key, value)
        end
        cleaned.presence
      end

      def sanitized_target_value(key, value)
        if IDENTIFIER_KEYS.include?(key)
          IdentifierValidator.valid?(value) ? value.to_s : INVALID_VALUE_MARKER
        elsif key == :status
          ALLOWED_STATUSES.include?(value.to_s) ? value.to_s : INVALID_VALUE_MARKER
        elsif key == :privilege_level
          ALLOWED_PRIVILEGE_LEVELS.include?(value.to_s) ? value.to_s : INVALID_VALUE_MARKER
        else
          INVALID_VALUE_MARKER
        end
      end

      def sanitized_detail
        return nil if @detail.blank?

        # Detail is expected to be a short, safe label (e.g. an i18n key or stage
        # name). Truncate defensively so a stray message can't dump a payload.
        @detail.to_s[0, 120]
      end
    end
  end
end
