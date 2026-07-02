# frozen_string_literal: true

require_relative 'routing_service'

module Wijaya
  module Batteries
    module MetaAdsTeamRouting
      # Thin hook surface called from Chatwoot core channel builders/services right before
      # a brand-new Conversation is created. Mutates conversation_params in place, injecting
      # only team_id. Safe no-op for organic traffic or when team_id is already present.
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
