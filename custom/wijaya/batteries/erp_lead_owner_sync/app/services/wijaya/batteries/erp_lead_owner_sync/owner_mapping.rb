# frozen_string_literal: true

require 'json'

# Resolves a Chatwoot assignee to an explicit ERPNext User name using the shared
# erp_lead_sidebar map (custom/.../erp_lead_sidebar/agent_erp_user_map.json). The
# map is installation-wide and its keys are ambiguous (id OR display name) because
# the frontend autofill tolerates either; for this server-side sync we key ONLY on
# the stable Chatwoot user id (a string), never name/email, so a rename can never
# silently re-point an owner. An unmapped agent returns nil, which the caller treats
# as "leave the existing ERP owner untouched". The resolved value is still validated
# as a real ERP User by the caller before any write; nothing here is trusted as-is.
module Wijaya
  module Batteries
    module ErpLeadOwnerSync
      module OwnerMapping
        MAP_PATH = Rails.root.join('custom/wijaya/batteries/erp_lead_sidebar/agent_erp_user_map.json')

        module_function

        def erp_user_for(user)
          return nil if user.nil?

          table[user.id.to_s].to_s.strip.presence
        end

        def table
          raw = File.read(MAP_PATH)
          parsed = JSON.parse(raw.presence || '{}')
          parsed.is_a?(Hash) ? parsed : {}
        rescue Errno::ENOENT, JSON::ParserError
          {}
        end
      end
    end
  end
end
