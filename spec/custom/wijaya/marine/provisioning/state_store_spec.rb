# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Provisioning::StateStore do
  describe 'defaults' do
    it 'reports not_provisioned when nothing is stored' do
      expect(described_class.current['status']).to eq('not_provisioned')
      expect(described_class.provisioned?).to be(false)
      expect(described_class.exists?).to be(false)
    end
  end

  describe '.write!' do
    it 'persists only whitelisted, non-secret keys' do
      described_class.write!(
        status: 'active',
        database_name: 'marine_erp',
        login_username: 'marine_app',
        password: 'should-never-persist',
        secret: 'nope'
      )

      stored = InstallationConfig.find_by(name: described_class::CONFIG_NAME).value
      expect(stored['status']).to eq('active')
      expect(stored['database_name']).to eq('marine_erp')
      expect(stored).not_to have_key('password')
      expect(stored).not_to have_key('secret')
      expect(stored.to_s).not_to include('should-never-persist')
    end

    it 'marks the record unlocked and merges subsequent writes' do
      described_class.write!(status: 'active', database_name: 'marine_erp', login_username: 'marine_app')
      described_class.write!(privilege_level: 'writer')

      expect(described_class.current['database_name']).to eq('marine_erp')
      expect(described_class.current['privilege_level']).to eq('writer')
      expect(described_class.provisioned?).to be(true)
    end
  end
end
