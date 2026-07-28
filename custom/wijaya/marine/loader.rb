require 'fileutils'

module Wijaya
  module Marine
    module Loader
      ROOT = Rails.root.join('custom/wijaya/marine')
      AUTOLOAD_DIRS = %w[
        app/models
        app/models/concerns
        app/services
        app/jobs
        app/controllers
        app/policies
        lib
      ].freeze

      # The Marine PostgreSQL provisioning feature lives in its own battery under
      # custom/wijaya/batteries/marine_ai. Its app/ subtree is autoloaded here so the
      # Marine::Provisioning services, the provisioning controller, and the
      # provisioning policy resolve through Zeitwerk exactly like the core marine app.
      PROVISIONING_BATTERY_ROOT = Rails.root.join('custom/wijaya/batteries/marine_ai')
      PROVISIONING_AUTOLOAD_DIRS = %w[
        app/services
        app/controllers
        app/policies
      ].freeze

      module_function

      def setup!
        ensure_root!
        register_autoload_paths!
        register_provisioning_battery_paths!
        load_extensions!
        attach_extensions!
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

      def register_provisioning_battery_paths!
        return unless File.directory?(PROVISIONING_BATTERY_ROOT)

        PROVISIONING_AUTOLOAD_DIRS.each do |relative_path|
          path = PROVISIONING_BATTERY_ROOT.join(relative_path)
          next unless File.directory?(path)
          next if registered_autoload_path?(path)

          Rails.autoloaders.main.push_dir(path)
        end
      end

      def registered_autoload_path?(path)
        Rails.autoloaders.main.dirs.any? { |dir| File.expand_path(dir) == path.to_s }
      end

      def load_extensions!
        require_dependency ROOT.join('app/models/concerns/wijaya/marine/account_extensions').to_s
        require_dependency ROOT.join('app/models/concerns/wijaya/marine/inbox_extensions').to_s
        require_dependency ROOT.join('app/services/wijaya/marine/hooks').to_s
      end

      def attach_extensions!
        Rails.application.config.to_prepare do
          Account.include Wijaya::Marine::AccountExtensions unless Account < Wijaya::Marine::AccountExtensions
          Inbox.include Wijaya::Marine::InboxExtensions unless Inbox < Wijaya::Marine::InboxExtensions
        end
      end
    end
  end
end
