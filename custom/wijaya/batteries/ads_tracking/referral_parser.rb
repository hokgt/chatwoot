# frozen_string_literal: true

module Wijaya
  module Batteries
    module AdsTracking
      class ReferralParser
        FIELD_KEYS = %i[
          channel source_id source_url source_type headline body media_type image_url video_url thumbnail_url ctwa_clid ref post_id product_id
        ].freeze

        def self.parse(channel:, referral:)
          new(channel: channel, referral: referral).parse
        end

        def initialize(channel:, referral:)
          @channel = channel.to_s
          @referral = referral.respond_to?(:with_indifferent_access) ? referral.with_indifferent_access : referral
        end

        def parse
          return if @referral.blank?

          normalized = normalized_payload
          normalized.compact_blank.presence && normalized
        end

        private

        def normalized_payload
          FIELD_KEYS.index_with { |key| value_for(key) }
        end

        def value_for(key)
          case key
          when :channel then @channel
          when :source_id then source_id
          when :source_url then whatsapp? ? @referral[:source_url] : nil
          when :source_type then normalize_source_type(source_type)
          when :headline then headline
          when :body then whatsapp? ? @referral[:body] : nil
          when :media_type then whatsapp? ? @referral[:media_type] : nil
          when :image_url then image_url
          when :video_url then video_url
          when :thumbnail_url then whatsapp? ? @referral[:thumbnail_url] : nil
          when :ctwa_clid then whatsapp? ? @referral[:ctwa_clid] : nil
          when :ref then whatsapp? ? nil : @referral[:ref]
          when :post_id then messenger? ? ads_context_data[:post_id] : nil
          when :product_id then messenger? ? ads_context_data[:product_id] : nil
          end
        end

        def whatsapp?
          @channel == 'whatsapp'
        end

        def messenger?
          @channel == 'messenger'
        end

        def source_id
          whatsapp? ? @referral[:source_id] : @referral[:ad_id]
        end

        def source_type
          whatsapp? ? @referral[:source_type] : @referral[:source]
        end

        def headline
          whatsapp? ? @referral[:headline] : ads_context_data[:ad_title]
        end

        def image_url
          whatsapp? ? @referral[:image_url] : ads_context_data[:photo_url]
        end

        def video_url
          whatsapp? ? @referral[:video_url] : ads_context_data[:video_url]
        end

        def ads_context_data
          @ads_context_data ||= (@referral[:ads_context_data] || {}).with_indifferent_access
        end

        def normalize_source_type(value)
          return if value.blank?

          normalized = value.to_s.downcase
          return 'ad' if normalized == 'ads'

          normalized
        end
      end
    end
  end
end
