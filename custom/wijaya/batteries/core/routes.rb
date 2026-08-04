# frozen_string_literal: true

# Generic route orchestrator for every Wijaya feature battery. Invoked once from
# config/routes.rb via `Wijaya::Batteries::Routes.draw(self)` inside the api/v1
# `scope module: :accounts` block. It owns NO endpoint definitions — only static
# wiring metadata (which battery owns a route module) and isolated, fail-open
# dispatch. Each battery's actual route definitions live in
# custom/wijaya/batteries/<feature>/routes.rb.
#
# Fails open per battery: each feature's routes are drawn in an isolated rescued
# block (StandardError and ScriptError), so a failure while requiring or drawing
# one battery is logged (class only) and swallowed without suppressing the other
# batteries or the native Chatwoot route set.
# Nested (not compact `module Wijaya::Batteries::Routes`) so this file is
# standalone-safe: core/loader.rb require_relatives it before any Wijaya parent
# constant exists, so a compact form would raise `uninitialized constant Wijaya`.
module Wijaya
  module Batteries
    module Routes
      module_function

      # Battery key => fully-qualified route module name. Wiring metadata only.
      ROUTE_MODULES = {
        marine_ai: 'Wijaya::Marine::Routes',
        meta_ads_team_routing: 'Wijaya::Batteries::MetaAdsTeamRouting::Routes',
        erp_lead_sidebar: 'Wijaya::Batteries::ErpLeadSidebar::Routes'
      }.freeze

      def draw(mapper)
        ROUTE_MODULES.each_key do |battery|
          draw_battery(mapper, battery)
        end
      end

      # Require and draw a single battery's routes in isolation. Battery route files
      # are loaded via `require` (not Zeitwerk) so their constants persist across dev
      # route reloads. Any failure is logged (class only) and swallowed so the
      # remaining batteries and native routes are unaffected.
      def draw_battery(mapper, battery)
        require Rails.root.join("custom/wijaya/batteries/#{battery}/routes").to_s
        ROUTE_MODULES[battery].constantize.draw(mapper)
      rescue StandardError, ScriptError => e
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.error("[Wijaya] route registration failed for #{battery}: #{e.class}")
        end
      end
    end
  end
end
