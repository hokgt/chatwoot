require 'rails_helper'

require Rails.root.join('custom/wijaya/batteries/ads_tracking/hooks')

describe Wijaya::Batteries::AdsTracking::Hooks do
  describe '.associate_referral_video!' do
    let(:message) { create(:message, content_attributes: { ads_referral: { media_type: 'video' } }) }
    let(:attachment) { instance_double(Attachment, persisted?: true, id: 123) }

    it 'records the stored attachment id on ads_referral' do
      described_class.associate_referral_video!(message: message, attachment: attachment)

      expect(message.reload.content_attributes['ads_referral']['video_attachment_id']).to eq(123)
    end

    it 'is nonfatal and returns nil when the column update fails' do
      allow(message).to receive(:update_column).and_raise(ActiveRecord::StatementInvalid.new('boom'))

      expect do
        expect(described_class.associate_referral_video!(message: message, attachment: attachment)).to be_nil
      end.not_to raise_error
      expect(message.reload.content_attributes['ads_referral']).not_to have_key('video_attachment_id')
    end

    it 'does nothing when no attachment was stored' do
      described_class.associate_referral_video!(message: message, attachment: nil)

      expect(message.reload.content_attributes['ads_referral']).not_to have_key('video_attachment_id')
    end
  end
end
