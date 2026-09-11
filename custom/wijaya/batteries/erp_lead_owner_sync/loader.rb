# frozen_string_literal: true

require 'fileutils'
require Rails.root.join('custom/wijaya/batteries/core/loader')

# Feature loader for the ERP Lead Owner Sync battery. It pushes the battery app/
# subtree (services + job) onto the Zeitwerk main autoloader so its constants load
# lazily by path (e.g. app/jobs/wijaya/batteries/erp_lead_owner_sync/owner_sync_job.rb
# -> Wijaya::Batteries::ErpLeadOwnerSync::OwnerSyncJob), and (inside to_prepare)
# requires + includes the ConversationExtensions concern into core Conversation so
# app/models/conversation.rb carries NO owner-sync code at all: the post-commit
# assignee-change seam stays entirely battery-owned.
#
# Nested (not compact `module Wijaya::Batteries::ErpLeadOwnerSync::Loader`) so this
# file is standalone-safe: the core loader's discover! requires it before any Wijaya
# parent constant exists; the nested declaration creates the namespace, where a
# compact form would raise `uninitialized constant Wijaya::Batteries::ErpLeadOwnerSync`.
module Wijaya
  module Batteries
    module ErpLeadOwnerSync
      module Loader
        ROOT = Rails.root.join('custom/wijaya/batteries/erp_lead_owner_sync')
        AUTOLOAD_DIRS = %w[app/services app/jobs].freeze

        module_function

        def setup!
          register_autoload_paths!
          attach_conversation_extensions!
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

        def attach_conversation_extensions!
          root = ROOT
          Rails.application.config.to_prepare do
            require root.join('conversation_extensions').to_s
            extensions = Wijaya::Batteries::ErpLeadOwnerSync::ConversationExtensions
            Conversation.include(extensions) unless extensions >= Conversation
          rescue StandardError, ScriptError => e
            Rails.logger.error("[Wijaya] erp_lead_owner_sync extension attach failed: #{e.class}")
          end
        end
      end
    end
  end
end

Wijaya::Batteries::Core::Loader.register(Wijaya::Batteries::ErpLeadOwnerSync::Loader)
