# frozen_string_literal: true

# Nested (not compact `class Wijaya::Batteries::AdsTracking::ReferralVideoFetcher`)
# so it is standalone-safe when `require_relative`d from ads_tracking/hooks.rb
# before the AdsTracking namespace exists (a compact form would raise
# `uninitialized constant Wijaya::Batteries::AdsTracking`).
#
# Safely turns a WhatsApp CTWA `referral.video_url` into a normal Message video
# Attachment/ActiveStorage blob so a genuinely downloadable ad creative can play
# inline, instead of pointing a <video> tag at the raw referral URL (which is
# frequently a Facebook page/Reel HTML document, not a media file). The fetch is
# routed through SafeFetch (ssrf_filter): it validates the scheme, blocks
# loopback/private/link-local/metadata targets, re-validates every redirect
# target, bounds redirects/timeout/byte-size, and accepts only a successful
# response whose content type is video/*. Everything here is best-effort: any
# failure returns nil so the message + referral still persist and the UI falls
# back to thumbnail + Watch ad.
module Wijaya
  module Batteries
    module AdsTracking
      class ReferralVideoFetcher
        include ::UrlHelper

        # Only accept responses whose actual media content type is video/*; a
        # facebook.com/reel or any page URL answers text/html and is rejected.
        ALLOWED_CONTENT_TYPE_PREFIXES = ['video/'].freeze

        def self.build_attachment(message:, ads_referral:)
          new(message: message, ads_referral: ads_referral).build_attachment
        end

        def initialize(message:, ads_referral:)
          @message = message
          @ads_referral = ads_referral.to_h.with_indifferent_access
        end

        def build_attachment
          return unless downloadable_video?

          fetch_and_attach
        rescue StandardError => e
          log_failure(e)
          nil
        end

        private

        attr_reader :message, :ads_referral

        # Directness is decided by the response content type (below), never by a
        # `.mp4` suffix; here we only gate on media_type and a present http(s) URL.
        def downloadable_video?
          ads_referral[:media_type].to_s.casecmp('video').zero? && url_valid?(ads_referral[:video_url].to_s)
        end

        def fetch_and_attach
          attachment = nil
          SafeFetch.fetch(ads_referral[:video_url], allowed_content_type_prefixes: ALLOWED_CONTENT_TYPE_PREFIXES) do |result|
            blob = ActiveStorage::Blob.create_and_upload!(
              io: result.tempfile,
              filename: result.filename,
              content_type: result.content_type
            )
            attachment = message.attachments.new(account_id: message.account_id, file_type: :video)
            attachment.file.attach(blob)
          end
          attachment
        end

        def log_failure(error)
          # Never log the URL itself — the ad video URL can carry signed Meta tokens.
          Rails.logger.warn("[ads_tracking] referral video fetch skipped: #{error.class}")
        end
      end
    end
  end
end
