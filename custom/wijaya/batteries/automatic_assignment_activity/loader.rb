# frozen_string_literal: true

require Rails.root.join('custom/wijaya/batteries/core/loader')

# Feature loader for the automatic-assignment activity battery. It owns no autoload
# paths and no ActiveRecord model; it only needs the hook surface loaded so the core
# dispatcher can resolve Wijaya::Batteries::AutomaticAssignmentActivity::Hooks. The
# require runs inside to_prepare so the module is re-established on every development
# reload (matching the other batteries), and hooks.rb pulls in system_assignment.rb.
# Nested (not compact) so this file is standalone-safe: the core loader's discover!
# requires it before Wijaya::Batteries::AutomaticAssignmentActivity exists; the nested
# declaration creates that namespace, where a compact form would raise NameError.
module Wijaya
  module Batteries
    module AutomaticAssignmentActivity
      module Loader
        ROOT = Rails.root.join('custom/wijaya/batteries/automatic_assignment_activity')

        module_function

        def setup!
          root = ROOT
          Rails.application.config.to_prepare do
            require root.join('hooks').to_s
          rescue StandardError, ScriptError => e
            Rails.logger.error("[Wijaya] automatic_assignment_activity extension attach failed: #{e.class}")
          end
        end
      end
    end
  end
end

Wijaya::Batteries::Core::Loader.register(Wijaya::Batteries::AutomaticAssignmentActivity::Loader)
