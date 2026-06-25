require 'rails_helper'

require Rails.root.join('custom/wijaya/batteries/ads_tracking/referral_parser')

describe Wijaya::Batteries::AdsTracking::ReferralParser do
  describe '.parse' do
    it 'normalizes WhatsApp referral payloads' do
      referral = {
        source_url: 'https://facebook.com/ad/1', source_id: 'wa-ad-1', source_type: 'ad', headline: 'WA Headline', body: 'WA Body',
        media_type: 'image', image_url: 'https://example.com/image.jpg', video_url: 'https://example.com/video.mp4',
        thumbnail_url: 'https://example.com/thumb.jpg', ctwa_clid: 'click-1'
      }.with_indifferent_access

      result = described_class.parse(channel: :whatsapp, referral: referral)

      expect(result).to include(
        channel: 'whatsapp', source_id: 'wa-ad-1', source_url: 'https://facebook.com/ad/1', source_type: 'ad',
        headline: 'WA Headline', body: 'WA Body', media_type: 'image', image_url: 'https://example.com/image.jpg',
        video_url: 'https://example.com/video.mp4', thumbnail_url: 'https://example.com/thumb.jpg', ctwa_clid: 'click-1'
      )
      expect(result).to include(ref: nil, post_id: nil, product_id: nil)
    end

    it 'normalizes Messenger referral payloads' do
      referral = {
        source: 'ADS', type: 'OPEN_THREAD', ref: 'custom-ref', ad_id: 'msg-ad-1',
        ads_context_data: { ad_title: 'Messenger Ad', photo_url: 'https://example.com/photo.jpg', video_url: 'https://example.com/video.jpg', post_id: 'post-1', product_id: 'product-1' }
      }.with_indifferent_access

      expect(described_class.parse(channel: :messenger, referral: referral)).to include(
        channel: 'messenger', source_id: 'msg-ad-1', source_type: 'ad', headline: 'Messenger Ad',
        image_url: 'https://example.com/photo.jpg', video_url: 'https://example.com/video.jpg', ref: 'custom-ref', post_id: 'post-1', product_id: 'product-1'
      )
    end

    it 'normalizes Instagram referral payloads with creative fields as nil' do
      referral = { source: 'ADS', type: 'OPEN_THREAD', ref: 'ig-ref', ad_id: 'ig-ad-1' }.with_indifferent_access

      expect(described_class.parse(channel: :instagram, referral: referral)).to include(
        channel: 'instagram', source_id: 'ig-ad-1', source_type: 'ad', ref: 'ig-ref', headline: nil, image_url: nil, video_url: nil
      )
    end

    it 'returns nil when referral is absent' do
      expect(described_class.parse(channel: :whatsapp, referral: nil)).to be_nil
    end
  end
end
