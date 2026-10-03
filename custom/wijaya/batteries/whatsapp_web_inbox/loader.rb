# frozen_string_literal: true

require 'fileutils'
require Rails.root.join('custom/wijaya/batteries/core/loader')

# Feature loader for the WhatsApp Web (Unofficial) inbox battery. Two jobs:
#
#   1. Wire its own app/ subtree into Zeitwerk: the ActiveRecord mapping model, the
#      plain-Ruby service objects (Config/RequestSigner/ConnectorClient/Provisioner),
#      the ActiveJob provisioning/cleanup jobs, and the account-scoped controllers all
#      autoload from there (constant names derive from the file paths, e.g.
#      app/models/wijaya/batteries/whatsapp_web_inbox/record.rb ->
#      Wijaya::Batteries::WhatsappWebInbox::Record).
#   2. Attach the battery InboxExtensions concern inside to_prepare, so the native
#      app/models/inbox.rb carries NO markers: the has_one mapping + dependent: :destroy
#      (which fires the connector-session cleanup job on inbox deletion) stay entirely
#      battery-owned.
#
# Nested (not compact `module Wijaya::Batteries::WhatsappWebInbox::Loader`) so this file
# is standalone-safe: the core loader's discover! requires it before any Wijaya parent
# constant exists; the nested declaration creates the namespace, where a compact form
# would raise `uninitialized constant Wijaya::Batteries::WhatsappWebInbox`.
module Wijaya
  module Batteries
    module WhatsappWebInbox
      module Loader
        ROOT = Rails.root.join('custom/wijaya/batteries/whatsapp_web_inbox')
        AUTOLOAD_DIRS = %w[app/controllers app/models app/services app/jobs].freeze

        module_function

        def setup!
          register_autoload_paths!
          attach_inbox_extensions!
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

        def attach_inbox_extensions!
          root = ROOT
          Rails.application.config.to_prepare do
            require root.join('inbox_extensions').to_s
            extensions = Wijaya::Batteries::WhatsappWebInbox::InboxExtensions
            Inbox.include(extensions) unless extensions >= Inbox
          rescue StandardError, ScriptError => e
            Rails.logger.error("[Wijaya] whatsapp_web_inbox extension attach failed: #{e.class}")
          end
        end
      end
    end
  end
end

Wijaya::Batteries::Core::Loader.register(Wijaya::Batteries::WhatsappWebInbox::Loader)
