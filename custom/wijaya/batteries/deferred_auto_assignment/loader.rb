# frozen_string_literal: true

require 'fileutils'
require Rails.root.join('custom/wijaya/batteries/core/loader')

# Feature loader for the deferred/native auto-assignment battery. Two jobs:
#
#   1. Wire its own app/ subtree into Zeitwerk: the ActiveRecord marker model, the plain-Ruby
#      service objects, and the coalescing job all autoload from there (constant names derive
#      from the file paths, e.g. app/models/wijaya/batteries/deferred_auto_assignment/marker.rb
#      -> Wijaya::Batteries::DeferredAutoAssignment::Marker). The core dispatcher resolves
#      Wijaya::Batteries::DeferredAutoAssignment::Hooks lazily by name, which Zeitwerk
#      autoloads on first reference, so there is nothing to require eagerly there.
#   2. Attach the battery ConversationExtensions concern (marker has_one dependent: :destroy +
#      the after_update_commit lifecycle cleanup) inside to_prepare, so app/models/conversation.rb
#      carries only the tiny registration seam and the child-marker lifecycle stays battery-owned.
#
# Nested (not compact `module Wijaya::Batteries::DeferredAutoAssignment::Loader`) so this
# file is standalone-safe: the core loader's discover! requires it before any Wijaya parent
# constant exists; the nested declaration creates the namespace, where a compact form would
# raise `uninitialized constant Wijaya::Batteries::DeferredAutoAssignment`.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module Loader
        ROOT = Rails.root.join('custom/wijaya/batteries/deferred_auto_assignment')
        AUTOLOAD_DIRS = %w[app/models app/services app/jobs].freeze

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
            extensions = Wijaya::Batteries::DeferredAutoAssignment::ConversationExtensions
            Conversation.include(extensions) unless extensions >= Conversation
          rescue StandardError, ScriptError => e
            Rails.logger.error("[Wijaya] deferred_auto_assignment extension attach failed: #{e.class}")
          end
        end
      end
    end
  end
end

Wijaya::Batteries::Core::Loader.register(Wijaya::Batteries::DeferredAutoAssignment::Loader)
