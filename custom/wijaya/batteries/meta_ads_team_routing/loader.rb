# frozen_string_literal: true

require 'fileutils'
require Rails.root.join('custom/wijaya/batteries/core/loader')

# Feature loader for the Meta Ads -> Team routing battery. Registers the battery
# controller directory with Zeitwerk and requires the model/service/hooks inside
# to_prepare (the ApplicationRecord-backed model must (re)load on boot and on each
# development reload). hooks.rb pulls in routing_service, which pulls in routing_rule.
# Nested (not compact `module Wijaya::Batteries::MetaAdsTeamRouting::Loader`) so
# this file is standalone-safe: it is required directly by the core loader's
# discover! before Wijaya::Batteries::MetaAdsTeamRouting exists. The nested
# declaration creates that namespace at boot; a compact form raises
# `uninitialized constant Wijaya::Batteries::MetaAdsTeamRouting`.
module Wijaya
  module Batteries
    module MetaAdsTeamRouting
      module Loader
        ROOT = Rails.root.join('custom/wijaya/batteries/meta_ads_team_routing')
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

        def load_models!
          root = ROOT
          Rails.application.config.to_prepare do
            require root.join('hooks').to_s
          rescue StandardError, ScriptError => e
            Rails.logger.error("[Wijaya] meta_ads_team_routing extension attach failed: #{e.class}")
          end
        end
      end
    end
  end
end

Wijaya::Batteries::Core::Loader.register(Wijaya::Batteries::MetaAdsTeamRouting::Loader)
