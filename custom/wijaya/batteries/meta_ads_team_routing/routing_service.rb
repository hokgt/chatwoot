# frozen_string_literal: true

require_relative '../ads_tracking/referral_parser'
require_relative 'routing_rule'

module Wijaya
  module Batteries
    module MetaAdsTeamRouting
      # Central routing resolver. Given a channel referral payload, normalizes it to a
      # source_id (via the existing AdsTracking parser), finds an active account-scoped
      # mapping, and injects only params[:team_id] so Chatwoot's native assignment engine
      # sees the team naturally at Conversation.create! time.
      #
      # It never sets assignee_id and never overrides an existing team_id. Organic traffic
      # (no referral / no source_id / no active mapping) is left untouched.
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
          @conversation_params = conversation_params
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
