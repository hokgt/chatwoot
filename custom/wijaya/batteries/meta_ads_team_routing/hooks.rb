# frozen_string_literal: true

require_relative 'routing_service'

# Thin hook surface called from Chatwoot core channel builders/services right before
# a brand-new Conversation is created. Returns a new conversation_params hash with
# team_id injected; the caller's hash is never mutated. Safe no-op (returns an
# equivalent copy) for organic traffic or when team_id is already present.
# Nested (not compact `module Wijaya::Batteries::MetaAdsTeamRouting::Hooks`) so the
# unqualified `RoutingService` reference below resolves lexically: nested declarations
# put every parent (…::MetaAdsTeamRouting) into Module.nesting, so the sibling constant
# is found. A compact form leaves only …::Hooks in the nesting, so `RoutingService`
# raises NameError at call time and the core dispatcher silently fails open.
module Wijaya
  module Batteries
    module MetaAdsTeamRouting
      module Hooks
        module_function

        def apply_team_routing!(account:, inbox:, channel:, referral:, conversation_params:)
          RoutingService.apply!(
            account: account,
            inbox: inbox,
            channel: channel,
            referral: referral,
            conversation_params: conversation_params
          )
        end
      end
    end
  end
end
