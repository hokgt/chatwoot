# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Provisioning::IdentifierValidator do
  describe '.validate!' do
    it 'accepts a valid lowercase identifier' do
      expect(described_class.validate!('marine_erp', label: 'Database name')).to eq('marine_erp')
    end

    it 'rejects a blank value' do
      expect { described_class.validate!('  ', label: 'Database name') }
        .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
    end

    it 'rejects values longer than 63 bytes' do
      expect { described_class.validate!('a' * 64, label: 'Database name') }
        .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
    end

    it 'rejects uppercase / illegal characters (would require quoting)' do
      expect { described_class.validate!('Marine-ERP', label: 'Database name') }
        .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
    end

    it 'rejects names starting with a digit' do
      expect { described_class.validate!('1marine', label: 'Database name') }
        .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
    end

    it 'rejects reserved / system names' do
      %w[postgres public template1 pg_catalog pg_toast_temp information_schema].each do |name|
        expect { described_class.validate!(name, label: 'Database name') }
          .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
      end
    end

    it 'rejects the current Chatwoot database and role names via extra_reserved' do
      expect { described_class.validate!('chatwoot_prod', label: 'Database name', extra_reserved: %w[chatwoot_prod]) }
        .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
    end

    it 'never includes the raw offending value in the error message' do
      described_class.validate!('DROP TABLE users', label: 'Database name')
    rescue Marine::Provisioning::Errors::InvalidIdentifierError => e
      expect(e.message).not_to include('DROP TABLE users')
      expect(e.i18n_key).to eq('PROVISIONING.ERRORS.INVALID_IDENTIFIER')
    end
  end
end
