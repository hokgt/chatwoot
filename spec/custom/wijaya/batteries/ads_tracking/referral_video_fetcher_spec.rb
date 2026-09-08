require 'rails_helper'

require Rails.root.join('custom/wijaya/batteries/ads_tracking/referral_video_fetcher')

describe Wijaya::Batteries::AdsTracking::ReferralVideoFetcher do
  subject(:build_attachment) { described_class.build_attachment(message: message, ads_referral: ads_referral) }

  let(:message) { create(:message) }
  let(:video_url) { 'https://cdn.example.com/creative' }
  let(:ads_referral) do
    { channel: 'whatsapp', media_type: 'video', video_url: video_url, thumbnail_url: 'https://cdn.example.com/thumb.jpg' }
  end

  def stub_fetch_yielding(content_type:, filename: 'creative.mp4')
    result = SafeFetch::Result.new(tempfile: StringIO.new('fake-video-bytes'), filename: filename, content_type: content_type)
    allow(SafeFetch).to receive(:fetch).and_yield(result)
  end

  context 'when the referral video is a downloadable video/* resource' do
    before { stub_fetch_yielding(content_type: 'video/mp4') }

    it 'only accepts video content types from the fetcher' do
      build_attachment
      expect(SafeFetch).to have_received(:fetch).with(video_url, allowed_content_type_prefixes: ['video/'])
    end

    it 'builds a video attachment backed by an ActiveStorage blob' do
      attachment = build_attachment
      expect(attachment).to be_present
      expect(attachment.file_type).to eq('video')
      expect(attachment.file).to be_attached
      expect(attachment.account_id).to eq(message.account_id)
    end

    it 'persists as a normal message video attachment when saved' do
      attachment = build_attachment
      expect { attachment.save! }.to change { message.reload.attachments.count }.by(1)
      expect(message.attachments.first.file_type).to eq('video')
    end
  end

  context 'when the URL responds with an HTML page (e.g. a Facebook Reel)' do
    before do
      allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::UnsupportedContentTypeError.new('content-type not allowed: text/html'))
    end

    let(:video_url) { 'https://www.facebook.com/reel/1438165771395493/' }

    it 'creates no attachment' do
      expect(build_attachment).to be_nil
    end
  end

  context 'when the download fails' do
    before { allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::FetchError.new('timeout')) }

    it 'is nonfatal and creates no attachment' do
      expect { build_attachment }.not_to raise_error
      expect(build_attachment).to be_nil
    end
  end

  context 'when the URL is unsafe or non-http' do
    let(:video_url) { 'javascript:alert(1)' }

    it 'does not attempt a fetch and creates no attachment' do
      expect(SafeFetch).not_to receive(:fetch)
      expect(build_attachment).to be_nil
    end
  end

  context 'when video_url is absent' do
    let(:ads_referral) { { channel: 'whatsapp', media_type: 'video', video_url: nil } }

    it 'does not attempt a fetch and creates no attachment' do
      expect(SafeFetch).not_to receive(:fetch)
      expect(build_attachment).to be_nil
    end
  end

  context 'when the referral is not a video' do
    let(:ads_referral) { { channel: 'whatsapp', media_type: 'image', image_url: 'https://cdn.example.com/image.jpg', video_url: video_url } }

    it 'does not attempt a fetch and creates no attachment' do
      expect(SafeFetch).not_to receive(:fetch)
      expect(build_attachment).to be_nil
    end
  end
end
