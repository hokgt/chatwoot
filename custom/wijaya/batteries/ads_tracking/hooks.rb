# frozen_string_literal: true

require_relative 'referral_parser'

module Wijaya
  module Batteries
    module AdsTracking
      module Hooks
        module_function

        def facebook_referral(messaging)
          messaging.dig('message', 'referral')
        end

        def append_ads_referral!(content_attributes:, channel:, referral:, conversation:, outgoing_echo: false)
          return if outgoing_echo
          return if referral.blank?
          return if conversation.messages.incoming.exists?

          ads_referral = ReferralParser.parse(channel: channel, referral: referral)
          content_attributes[:ads_referral] = ads_referral if ads_referral.present?
        end
      end
    end
  end
end
