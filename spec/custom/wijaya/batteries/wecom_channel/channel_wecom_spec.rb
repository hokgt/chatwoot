# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channel::Wecom do
  describe 'validations' do
    subject(:channel) { build(:channel_wecom, account: account) }

    let(:account) { create(:account) }

    it { is_expected.to be_valid }

    it 'requires corp_id, token and encoding_aes_key but not secret/open_kfid' do
      channel = build(:channel_wecom, :unconfigured, account: account)
      expect(channel).to be_valid
    end

    it 'rejects a blank corp_id' do
      channel.corp_id = nil
      expect(channel).not_to be_valid
    end

    it 'enforces the 43-character EncodingAESKey length' do
      channel.encoding_aes_key = 'tooshort'
      expect(channel).not_to be_valid
    end

    it 'allows multiple blank open_kfid rows (uniqueness skips blanks)' do
      create(:channel_wecom, :unconfigured)
      expect(build(:channel_wecom, :unconfigured, account: account)).to be_valid
    end

    it 'normalizes a blank-string open_kfid to nil before validation' do
      channel.open_kfid = ''
      channel.valid?
      expect(channel.open_kfid).to be_nil
    end

    it 'persists multiple empty-string open_kfid rows without tripping the unique index' do
      create(:channel_wecom, open_kfid: '')
      second = build(:channel_wecom, open_kfid: '', account: account)
      expect(second.save).to be(true)
      expect(second.reload.open_kfid).to be_nil
    end

    it 'rejects a duplicate non-blank open_kfid' do
      existing = create(:channel_wecom)
      expect(build(:channel_wecom, open_kfid: existing.open_kfid)).not_to be_valid
    end
  end

  describe 'Open KF ID auto-discovery' do
    it 'enqueues discovery when a Secret is first saved while open_kfid is blank' do
      channel = create(:channel_wecom, :unconfigured)
      expect do
        channel.update!(secret: 'freshly-revealed-secret')
      end.to have_enqueued_job(Wijaya::Batteries::WecomChannel::AutofillKfAccountJob).with(channel_id: channel.id)
    end

    it 'does not enqueue discovery when open_kfid is already set' do
      channel = create(:channel_wecom, secret: nil, open_kfid: 'wk-existing')
      expect do
        channel.update!(secret: 'freshly-revealed-secret')
      end.not_to have_enqueued_job(Wijaya::Batteries::WecomChannel::AutofillKfAccountJob)
    end
  end
end
