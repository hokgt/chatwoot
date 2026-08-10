# frozen_string_literal: true

require 'json'

# Battery-owned, trusted single source of truth mapping a Chatwoot agent to the
# exact ERPNext User.name that should be recorded as a Lead Activity's
# "person in charge".
#
# Why this exists: the browser must never be able to pick which ERP user is
# recorded. The server derives the mapped candidate itself, from the server-side
# conversation assignee (see LeadActivityService), looks it up here, and even
# then re-confirms the result against ERPNext before recording it.
#
# The mapping data lives in agent_erp_user_map.json in this battery directory,
# read verbatim by BOTH this module and the frontend (frontend/mappings.js) so
# the two can never diverge. JSON object keys are strings: they are the Chatwoot
# agent id (as a string) or the agent display name; values are exact ERP
# User.name strings. The committed file is intentionally EMPTY of real
# identities: real mappings must stay source-controlled and may only be added by
# a future, explicitly approved code change — never by hand-editing a deployed
# copy. With an empty map the behavior is "no verified person in charge"
# (normalized to empty), the documented Phase-1 default, which fails safe.
#
# Lookup is by assignee id or display name only — NEVER the agent's email.
#
# Declared with the nested module style (matching the sibling battery files) so
# ErpLeadSidebar stays in Module.nesting.
module Wijaya::Batteries::ErpLeadSidebar
  module LeadActivityPersonDirectory
    MAP_PATH = File.expand_path('agent_erp_user_map.json', __dir__)

    # Loaded once at require time from the shared JSON. Keys are strings (agent
    # id-as-string or display name); values are exact ERP User.name strings.
    MAP = begin
      parsed = JSON.parse(File.read(MAP_PATH))
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end.freeze

    module_function

    # The pre-approved ERP User.name for this assignee, or '' when the assignee
    # has no explicit mapping. Resolves by id or display name only; never the
    # assignee's own email.
    def erp_user_for(assignee)
      return '' if assignee.nil?

      by_id = MAP[assignee.id.to_s] if assignee.respond_to?(:id)
      by_name = MAP[assignee.name.to_s] if assignee.respond_to?(:name)
      (by_id || by_name).to_s
    end
  end
end
