# frozen_string_literal: true

require 'fileutils'
require Rails.root.join('custom/wijaya/batteries/core/loader')

# Feature loader for the ERP Lead Sidebar battery. Registers the battery controller
# directory with Zeitwerk and requires the ApplicationRecord-backed model + services
# inside to_prepare (they depend on ApplicationRecord, so they must (re)load on boot
# and on each development reload).
# Nested (not compact `module Wijaya::Batteries::ErpLeadSidebar::Loader`) so this
# file is standalone-safe: it is required directly by the core loader's discover!
# before Wijaya::Batteries::ErpLeadSidebar exists. The nested declaration creates
# that namespace at boot; a compact form raises `uninitialized constant
# Wijaya::Batteries::ErpLeadSidebar`.
module Wijaya
  module Batteries
    module ErpLeadSidebar
      module Loader
        ROOT = Rails.root.join('custom/wijaya/batteries/erp_lead_sidebar')
        AUTOLOAD_DIRS = %w[app/controllers].freeze

        module_function

        def setup!
          register_autoload_paths!
          load_models!
        end

        def register_autoload_paths!
          AUTOLOAD_DIRS.each do |relative_path|
            path = ROOT.join(relative_path)
            next unless File.directory?(path)
            next if registered_autoload_path?(path)

            Rails.autoloaders.main.push_dir(path)
          end
        end

        def registered_autoload_path?(path)
          Rails.autoloaders.main.dirs.any? { |dir| File.expand_path(dir) == path.to_s }
        end

        def load_models! # rubocop:disable Metrics/AbcSize
          root = ROOT
          Rails.application.config.to_prepare do
            require root.join('config').to_s
            require root.join('host_validator').to_s
            require root.join('erp_setting').to_s
            require root.join('lead_draft').to_s
            require root.join('payload_builder').to_s
            require root.join('sync_service').to_s
            require root.join('safe_http').to_s
            require root.join('refresh_service').to_s
            require root.join('options_service').to_s
            require root.join('connection_test_service').to_s
            require root.join('conversation_extensions').to_s
            extensions = Wijaya::Batteries::ErpLeadSidebar::ConversationExtensions
            Conversation.include extensions unless extensions >= Conversation
          rescue StandardError, ScriptError => e
            Rails.logger.error("[Wijaya] erp_lead_sidebar extension attach failed: #{e.class}")
          end
        end
      end
    end
  end
end

Wijaya::Batteries::Core::Loader.register(Wijaya::Batteries::ErpLeadSidebar::Loader)
