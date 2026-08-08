# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::ErpLeadSidebar::Config do
  let(:account) { create(:account) }

  describe 'credential resolution' do
    context 'when the account has no saved settings row' do
      it 'falls back to the global ENV values' do
        with_modified_env(
          WIJAYA_ERP_BASE_URL: 'https://env.example.com',
          WIJAYA_ERP_API_KEY: 'env-key',
          WIJAYA_ERP_API_SECRET: 'env-secret'
        ) do
          expect(described_class.erp_base_url(account)).to eq('https://env.example.com')
          expect(described_class.erp_api_key(account)).to eq('env-key')
          expect(described_class.erp_api_secret(account)).to eq('env-secret')
          expect(described_class.erp_configured?(account)).to be(true)
        end
      end
    end

    context 'when the account has a saved settings row' do
      before do
        Wijaya::ErpSetting.create!(
          account: account,
          host: 'https://saved.example.com',
          api_key: 'saved-key',
          api_secret: 'saved-secret'
        )
      end

      it 'uses the saved row and never consults ENV (row is authoritative)' do
        with_modified_env(
          WIJAYA_ERP_BASE_URL: 'https://env.example.com',
          WIJAYA_ERP_API_KEY: 'env-key',
          WIJAYA_ERP_API_SECRET: 'env-secret'
        ) do
          expect(described_class.erp_base_url(account)).to eq('https://saved.example.com')
          expect(described_class.erp_api_key(account)).to eq('saved-key')
          expect(described_class.erp_api_secret(account)).to eq('saved-secret')
        end
      end
    end

    context 'when a saved row exists with only a host (blank credentials)' do
      before { Wijaya::ErpSetting.create!(account: account, host: 'https://saved.example.com') }

      it 'does not borrow ENV credentials for the missing fields' do
        with_modified_env(WIJAYA_ERP_API_KEY: 'env-key', WIJAYA_ERP_API_SECRET: 'env-secret') do
          expect(described_class.erp_api_key(account)).to be_nil
          expect(described_class.erp_api_secret(account)).to be_nil
          expect(described_class.erp_configured?(account)).to be(false)
        end
      end
    end

    context 'when no account is passed (legacy global caller)' do
      it 'resolves ENV only' do
        with_modified_env(WIJAYA_ERP_BASE_URL: 'https://env.example.com') do
          expect(described_class.erp_base_url).to eq('https://env.example.com')
        end
      end
    end
  end

  describe '.erp_setting_for' do
    it 'does not swallow a genuine query error into a silent nil' do
      allow(Wijaya::ErpSetting).to receive(:table_exists?).and_return(true)
      allow(Wijaya::ErpSetting).to receive(:find_by).and_raise(ActiveRecord::StatementInvalid, 'boom')
      expect { described_class.erp_setting_for(account) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it 'returns nil when the backing table does not exist yet' do
      allow(Wijaya::ErpSetting).to receive(:table_exists?).and_return(false)
      expect(described_class.erp_setting_for(account)).to be_nil
    end
  end
end
