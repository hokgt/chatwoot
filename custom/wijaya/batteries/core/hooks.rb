# frozen_string_literal: true

# Generic, fail-open dispatcher for the handful of native Chatwoot runtime
# touchpoints that hand control to an optional Wijaya feature battery.
#
# A native hot path calls:
#
#   Wijaya::Batteries::Core::Hooks.dispatch(:feature, :hook_name, default: X, **kwargs)
#
# The dispatcher resolves the feature's Hooks module lazily by name, invokes
# the named hook, and GUARANTEES it never raises back into the native caller.
# If the feature battery is missing, disabled, unconfigured, or its hook raises
# for any reason, the caller-supplied +default+ is returned and the native code
# path continues exactly as upstream. It never loads secret values and never
# causes a boot failure (the map is static metadata; module resolution is lazy).
#
# This module owns NO business logic — only safe orchestration. All feature
# behaviour lives under custom/wijaya/batteries/<feature>/.
# Nested (not compact `module Wijaya::Batteries::Core::Hooks`) so this file is
# standalone-safe: core/loader.rb require_relatives it before any Wijaya parent
# constant exists, so a compact form would raise `uninitialized constant Wijaya`.
module Wijaya
  module Batteries
    module Core
      module Hooks
        # Feature key => fully-qualified Hooks module name. This is wiring metadata
        # (which battery owns which named integration surface), not business logic.
        # A feature absent from this map, or whose module cannot be resolved, simply
        # fails open to the native default.
        FEATURE_HOOK_MODULES = {
          meta_ads_team_routing: 'Wijaya::Batteries::MetaAdsTeamRouting::Hooks',
          marine_ai: 'Wijaya::Marine::Hooks',
          development_version: 'Wijaya::Batteries::DevelopmentVersion::Hooks',
          automatic_assignment_activity: 'Wijaya::Batteries::AutomaticAssignmentActivity::Hooks'
        }.freeze

        module_function

        # Invoke +hook+ on the +feature+'s Hooks module, failing open to +default+.
        # Never raises. Keyword args are forwarded verbatim to the hook.
        def dispatch(feature, hook, default: nil, **)
          mod = feature_module(feature)
          return default unless mod.respond_to?(hook)

          mod.public_send(hook, **)
        rescue StandardError, ScriptError => e
          report(feature, hook, e)
          default
        end

        # Resolve the feature's Hooks module, or a null object that responds to
        # nothing so callers uniformly fall through to their default.
        def feature_module(feature)
          name = FEATURE_HOOK_MODULES[feature]
          return NULL_MODULE unless name

          name.constantize
        rescue NameError, ScriptError
          NULL_MODULE
        end

        # Log the failing feature/hook and error class only. Never the error
        # message, which may embed remote response bodies or configured values.
        def report(feature, hook, error)
          return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

          Rails.logger.error("[Wijaya] hook #{feature}##{hook} failed open: #{error.class}")
        end

        # Responds to no hook name, so dispatch always returns the native default
        # when a feature battery is unavailable.
        NULL_MODULE = Object.new.freeze
      end
    end
  end
end
