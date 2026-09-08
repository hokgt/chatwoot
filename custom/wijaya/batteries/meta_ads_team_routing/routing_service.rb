# frozen_string_literal: true

require_relative '../ads_tracking/referral_parser'
require_relative 'routing_rule'

# Central routing resolver. Given a channel referral payload, normalizes it to a
# source_id (via the existing AdsTracking parser), finds an active account-scoped
# mapping, and injects only team_id so Chatwoot's native assignment engine sees the
# team naturally at Conversation.create! time.
#
# Operates on an isolated duplicate of the passed conversation_params and RETURNS the
# resulting params; the caller's hash is never mutated, so a raise anywhere leaves the
# native default untouched. Never sets assignee_id and never overrides an existing
# team_id. Organic traffic (no referral / no source_id / no active mapping) is left
# untouched.
# Nested (not compact `class Wijaya::Batteries::MetaAdsTeamRouting::RoutingService`) so
# this file is standalone-safe: it is `require_relative`d at the top of
# meta_ads_team_routing/hooks.rb (before that file declares its own module), so a compact
# form would raise `uninitialized constant Wijaya::Batteries::MetaAdsTeamRouting` if the
# feature loader has not yet created the parent namespace.
module Wijaya
  module Batteries
    module MetaAdsTeamRouting
      class RoutingService
        def self.apply!(account:, inbox:, channel:, referral:, conversation_params:)
          new(
            account: account,
            inbox: inbox,
            channel: channel,
            referral: referral,
            conversation_params: conversation_params
          ).apply!
        end

        def initialize(account:, inbox:, channel:, referral:, conversation_params:)
          @account = account
          @inbox = inbox
          @channel = channel
          @referral = referral
          # Work on an isolated copy so the caller's hash is never mutated.
          @conversation_params = conversation_params.dup
        end

        def apply!
          return @conversation_params if team_already_set?
          return @conversation_params if @account.blank?

          source_id = normalized_source_id
          return @conversation_params if source_id.blank?

          rule = active_rule_for(source_id)
          return @conversation_params if rule.blank?

          @conversation_params[:team_id] = rule.team_id
          @conversation_params
        end

        private

        def team_already_set?
          @conversation_params[:team_id].present? || @conversation_params['team_id'].present?
        end

        def normalized_source_id
          normalized = Wijaya::Batteries::AdsTracking::ReferralParser.parse(channel: @channel, referral: @referral)
          normalized && normalized[:source_id].presence
        end

        def active_rule_for(source_id)
          Wijaya::MetaAdsTeamRoutingRule.active.find_by(account_id: @account.id, source_id: source_id)
        end
      end
    end
  end
end
