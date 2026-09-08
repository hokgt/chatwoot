# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::ErpSetting do
  let(:account) { create(:account) }

  describe 'validations' do
    it 'is valid with an https origin host' do
      setting = described_class.new(account: account, host: 'https://erp.example.com')
      expect(setting).to be_valid
    end

    it 'requires a host' do
      setting = described_class.new(account: account, host: '')
      expect(setting).not_to be_valid
      expect(setting.errors[:host]).to be_present
    end

    it 'rejects a host with a path' do
      setting = described_class.new(account: account, host: 'https://erp.example.com/api')
      expect(setting).not_to be_valid
      expect(setting.errors[:host].join).to include('origin')
    end

    it 'rejects a plain http public host' do
      setting = described_class.new(account: account, host: 'http://erp.example.com')
      expect(setting).not_to be_valid
      expect(setting.errors[:host].join).to include('HTTPS')
    end

    it 'normalizes away a trailing slash before validation' do
      setting = described_class.create!(account: account, host: 'https://erp.example.com/')
      expect(setting.host).to eq('https://erp.example.com')
    end

    it 'enforces one row per account' do
      described_class.create!(account: account, host: 'https://erp.example.com')
      dup = described_class.new(account: account, host: 'https://other.example.com')
      expect(dup).not_to be_valid
      expect(dup.errors[:account_id]).to be_present
    end
  end

  describe 'credential encryption at rest' do
    it 'stores the api key/secret as ciphertext, not plaintext' do
      setting = described_class.create!(
        account: account,
        host: 'https://erp.example.com',
        api_key: 'plain-key-value',
        api_secret: 'plain-secret-value'
      )

      raw = described_class.connection.select_one(
        "SELECT api_key, api_secret FROM wijaya_erp_settings WHERE id = #{setting.id}"
      )
      expect(raw['api_key']).not_to include('plain-key-value')
      expect(raw['api_secret']).not_to include('plain-secret-value')
      expect(setting.reload.api_key).to eq('plain-key-value')
      expect(setting.reload.api_secret).to eq('plain-secret-value')
    end
  end
end
