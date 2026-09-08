# frozen_string_literal: true

require_relative 'referral_parser'
require_relative 'referral_video_fetcher'

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

        # Best-effort, WhatsApp-only: download an inline-playable ad video for the
        # first inbound referral message and stage it as an unsaved Message video
        # attachment. Returns nil (no attachment) for non-WhatsApp channels, echoes,
        # missing ads_referral, non-video referrals, missing/unsafe URLs, HTML/page
        # (Reel) responses, and any fetch failure. Called after other attachments
        # are built but before the message is saved.
        def build_referral_video_attachment(message:, channel:, outgoing_echo: false)
          return if outgoing_echo
          return unless channel.to_s == 'whatsapp'

          ads_referral = message.content_attributes&.with_indifferent_access&.dig(:ads_referral)
          return if ads_referral.blank?

          ReferralVideoFetcher.build_attachment(message: message, ads_referral: ads_referral)
        end

        # Record which stored attachment holds the downloaded ad creative so the UI
        # can use its normal attachment data_url as the inline source. `video_attachment_id`
        # is a Chatwoot-owned pointer (NOT a Meta-supplied field) and is only knowable
        # after save, so it is written with a callback-free column update.
        def associate_referral_video!(message:, attachment:)
          return if attachment.nil? || !attachment.persisted?

          attributes = message.content_attributes.to_h.deep_stringify_keys
          ads_referral = attributes['ads_referral']
          return if ads_referral.blank?

          ads_referral['video_attachment_id'] = attachment.id
          message.update_column(:content_attributes, attributes) # rubocop:disable Rails/SkipsModelValidations
        rescue StandardError => e
          # Best-effort pointer write: a failure here must never roll back the
          # already-saved incoming message. Log only the error class — the ad
          # referral can carry signed Meta URLs/tokens and customer data.
          Rails.logger.warn("[ads_tracking] referral video association skipped: #{e.class}")
          nil
        end
      end
    end
  end
end
