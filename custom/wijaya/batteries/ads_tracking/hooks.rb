# frozen_string_literal: true

require_relative 'referral_parser'

# Nested (not compact `module Wijaya::Batteries::AdsTracking::Hooks`) so this file
# is standalone-safe: native message builders `require_relative` it at their own
# load time, before the Wijaya battery initializer is guaranteed to have run. No
# loader creates the AdsTracking namespace, so this nested declaration is its sole
# creator; a compact form raises `uninitialized constant Wijaya::Batteries::AdsTracking`.
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
