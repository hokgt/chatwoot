# frozen_string_literal: true

# WIJAYA_CUSTOM_START core
# Single generic shim that boots the Wijaya battery system. All feature logic lives in
# each battery's own loader under custom/wijaya/batteries/<feature>/loader.rb; the generic
# core loader discovers and runs them, failing open (logging, never raising) so an absent
# or broken optional battery can never block Chatwoot boot.
begin
  require Rails.root.join('custom/wijaya/batteries/core/loader')
  Wijaya::Batteries::Core::Loader.setup!
rescue StandardError, ScriptError => e
  Rails.logger.error("[Wijaya] battery system boot skipped: #{e.class}") if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
end
# WIJAYA_CUSTOM_END core
