require 'fileutils'
require Rails.root.join('custom/wijaya/batteries/core/loader')

# Nested (not compact `module Wijaya::Marine::Loader`) so this file is
# standalone-safe: it is required directly by the core loader's discover! before
# Wijaya::Marine exists. The nested declaration is what creates Wijaya::Marine at
# boot; a compact form raises `uninitialized constant Wijaya::Marine` and the
# whole Marine battery silently fails open (the exact CI collection regression).
module Wijaya
  module Marine
    module Loader
      ROOT = Rails.root.join('custom/wijaya/batteries/marine_ai')
      AUTOLOAD_DIRS = %w[
        app/models
        app/models/concerns
        app/services
        app/jobs
        app/controllers
        app/policies
        lib
      ].freeze

      module_function

      def setup!
        ensure_root!
        register_autoload_paths!
        register_provisioning_battery_paths!
        register_locales!
        load_extensions!
        attach_extensions!
      end

      # Marine owns its own backend i18n. Appending to config.i18n.load_path during this
      # config-initializer phase is consumed by the i18n railtie at after_initialize, so
      # keys like marine.custom_tool.* resolve without living in core config/locales/en.yml.
      def register_locales!
        Rails.application.config.i18n.load_path += Dir[ROOT.join('config/locales/**/*.yml').to_s]
      end

      def ensure_root!
        FileUtils.mkdir_p(ROOT, mode: 0o775)
        FileUtils.chmod(0o775, ROOT) if File.directory?(ROOT)
      end

      def register_autoload_paths!
        AUTOLOAD_DIRS.each do |relative_path|
          path = ROOT.join(relative_path)
          FileUtils.mkdir_p(path, mode: 0o775)
          next if registered_autoload_path?(path)

          Rails.autoloaders.main.push_dir(path)
        end
      end

      # The Marine PostgreSQL provisioning feature (Marine::Provisioning services, the
      # provisioning controller, and the provisioning policy) now lives in this same
      # battery root under app/services, app/controllers, and app/policies, so it is
      # already wired into Zeitwerk by register_autoload_paths! above. This method is
      # retained as an explicit no-op hook so provisioning registration stays discoverable.
      def register_provisioning_battery_paths!
        # No-op: provisioning autoload dirs are covered by AUTOLOAD_DIRS under ROOT.
      end

      def registered_autoload_path?(path)
        Rails.autoloaders.main.dirs.any? { |dir| File.expand_path(dir) == path.to_s }
      end

      def load_extensions!
        require_dependency ROOT.join('app/models/concerns/wijaya/marine/account_extensions').to_s
        require_dependency ROOT.join('app/models/concerns/wijaya/marine/inbox_extensions').to_s
        require_dependency ROOT.join('app/models/concerns/wijaya/marine/user_extensions').to_s
        require_dependency ROOT.join('app/models/concerns/wijaya/marine/conversation_extensions').to_s
        require_dependency ROOT.join('app/models/concerns/wijaya/marine/active_storage_analysis_guard').to_s
        require_dependency ROOT.join('app/services/wijaya/marine/hooks').to_s
      end

      def attach_extensions!
        Rails.application.config.to_prepare do
          Account.include Wijaya::Marine::AccountExtensions unless Account < Wijaya::Marine::AccountExtensions
          Inbox.include Wijaya::Marine::InboxExtensions unless Inbox < Wijaya::Marine::InboxExtensions
          User.include Wijaya::Marine::UserExtensions unless User < Wijaya::Marine::UserExtensions
          Conversation.include Wijaya::Marine::ConversationExtensions unless Conversation < Wijaya::Marine::ConversationExtensions
          unless ActiveStorage::Attachment < Wijaya::Marine::ActiveStorageAnalysisGuard
            # Prepend inside the guarded to_prepare block, mirroring the sibling include calls above; an
            # on_load hook here would change load timing and break that consistency.
            ActiveStorage::Attachment.prepend Wijaya::Marine::ActiveStorageAnalysisGuard # rubocop:disable Rails/ActiveSupportOnLoad
          end
        rescue StandardError, ScriptError => e
          Rails.logger.error("[Wijaya] marine extension attach failed: #{e.class}")
        end
      end
    end
  end
end

Wijaya::Batteries::Core::Loader.register(Wijaya::Marine::Loader)
