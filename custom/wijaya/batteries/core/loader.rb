# frozen_string_literal: true

require 'fileutils'
require_relative 'hooks'
require_relative 'routes'

# Generic entry point for all Wijaya feature batteries. Discovers each battery's
# own `loader.rb`, requires it (which self-registers the feature loader here), then
# runs every registered feature loader's `setup!`. Each optional battery is isolated:
# a require failure or a setup! failure is logged and swallowed so a broken/absent
# optional battery can never prevent Chatwoot from booting (fail open at boot). The
# optional feature itself simply stays unavailable (fail closed).
#
# This module owns NO feature logic — only orchestration. Feature loaders own all
# autoload-path registration, model/service requires, and extension attachment.
# Nested (not compact `module Wijaya::Batteries::Core::Loader`) so this file is
# standalone-safe: it is required directly from config/initializers/wijaya.rb
# before Zeitwerk has autovivified any Wijaya parent constant. Nested declaration
# creates each parent as needed; a compact form would raise `uninitialized
# constant Wijaya::Batteries::Core` and the initializer would silently fail open.
module Wijaya
  module Batteries
    module Core
      module Loader
        BATTERIES_ROOT = Rails.root.join('custom/wijaya/batteries')

        # Registered feature loaders (each responds to `setup!`). This is an
        # append-at-require-time registry (see .register below), so it MUST stay
        # mutable; a RuboCop Style/MutableConstant autocorrection froze it, which
        # made every .register raise FrozenError inside discover! (swallowed), so
        # no feature setup! ran and all batteries silently stayed unloaded.
        REGISTRY = [] # rubocop:disable Style/MutableConstant

        module_function

        # Feature loaders call this at require time to register themselves.
        def register(feature_loader)
          REGISTRY << feature_loader unless REGISTRY.include?(feature_loader)
        end

        def setup!
          discover!
          REGISTRY.each do |feature_loader|
            feature_loader.setup!
          rescue StandardError, ScriptError => e
            Rails.logger.error("[Wijaya] battery loader setup failed: #{e.class}")
          end
        end

        # Require every `custom/wijaya/batteries/<feature>/loader.rb` except this one.
        # A require failure logs the battery dir and error class only (never the
        # error message or a full path, which may embed environment details).
        def discover!
          Dir[BATTERIES_ROOT.join('*/loader.rb').to_s].each do |loader_path|
            next if File.expand_path(loader_path) == File.expand_path(__FILE__)

            begin
              require loader_path
            rescue StandardError, ScriptError => e
              battery = File.basename(File.dirname(loader_path))
              Rails.logger.error("[Wijaya] failed to require battery loader #{battery}: #{e.class}")
            end
          end
        end
      end
    end
  end
end
