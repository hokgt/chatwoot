# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../custom/wijaya/batteries/test_database_safety/guard'

# Pure unit specs for the test-database isolation guard. These deliberately use the
# lightweight spec_helper (no Rails/DB boot) because the guard's whole purpose is to
# decide, without any database connection, whether a RAILS_ENV=test process is safe.
RSpec.describe Wijaya::Batteries::TestDatabaseSafety::Guard do
  let(:error) { Wijaya::Batteries::TestDatabaseSafety::UnsafeTestDatabaseError }

  describe '.safe_test_database_name' do
    it 'defaults to a safe chatwoot_test database' do
      expect(described_class.safe_test_database_name({})).to eq('chatwoot_test')
    end

    it 'ignores an inherited POSTGRES_DATABASE=chatwoot_production for test selection' do
      env = { 'POSTGRES_DATABASE' => 'chatwoot_production' }
      expect(described_class.safe_test_database_name(env)).to eq('chatwoot_test')
    end

    it 'accepts an explicit test-only POSTGRES_TEST_DATABASE' do
      env = { 'POSTGRES_TEST_DATABASE' => 'myapp_test', 'POSTGRES_DATABASE' => 'chatwoot_production' }
      expect(described_class.safe_test_database_name(env)).to eq('myapp_test')
    end

    it 'rejects a production POSTGRES_TEST_DATABASE' do
      env = { 'POSTGRES_TEST_DATABASE' => 'chatwoot_production' }
      expect { described_class.safe_test_database_name(env) }.to raise_error(error)
    end

    it 'rejects a POSTGRES_TEST_DATABASE name that is not clearly test-only' do
      env = { 'POSTGRES_TEST_DATABASE' => 'chatwoot' }
      expect { described_class.safe_test_database_name(env) }.to raise_error(error)
    end

    it 'rejects a POSTGRES_TEST_DATABASE that equals a non-test POSTGRES_DATABASE' do
      env = { 'POSTGRES_TEST_DATABASE' => 'chatwoot_production', 'POSTGRES_DATABASE' => 'chatwoot_production' }
      expect { described_class.safe_test_database_name(env) }
        .to raise_error(error, /must not equal the non-test POSTGRES_DATABASE/)
    end

    it 'rejects a production DATABASE_URL' do
      env = { 'DATABASE_URL' => 'postgres://appuser:s3cr3t@db.internal:5432/chatwoot_production' }
      expect { described_class.safe_test_database_name(env) }.to raise_error(error)
    end

    it 'never leaks credentials from a rejected DATABASE_URL' do
      env = { 'DATABASE_URL' => 'postgres://appuser:s3cr3t@db.internal:5432/chatwoot_production' }
      described_class.safe_test_database_name(env)
    rescue error => e
      expect(e.message).not_to include('s3cr3t')
      expect(e.message).not_to include('appuser')
      expect(e.message).not_to include('db.internal')
    end

    it 'accepts a test-only DATABASE_URL' do
      env = { 'DATABASE_URL' => 'postgres://appuser:s3cr3t@db.internal:5432/chatwoot_test' }
      expect(described_class.safe_test_database_name(env)).to eq('chatwoot_test')
    end

    it 'prefers and validates a test-only TEST_DATABASE_URL over a production DATABASE_URL' do
      env = {
        'TEST_DATABASE_URL' => 'postgres://u:p@host/app_test',
        'DATABASE_URL' => 'postgres://u:p@host/chatwoot_production'
      }
      expect(described_class.safe_test_database_name(env)).to eq('app_test')
    end

    it 'rejects a production TEST_DATABASE_URL' do
      env = { 'TEST_DATABASE_URL' => 'postgres://u:p@host/chatwoot_production' }
      expect { described_class.safe_test_database_name(env) }.to raise_error(error)
    end

    it 'rejects a malformed DATABASE_URL' do
      env = { 'DATABASE_URL' => 'not a valid url :::' }
      expect { described_class.safe_test_database_name(env) }.to raise_error(error)
    end

    it 'rejects a DATABASE_URL with no database name' do
      env = { 'DATABASE_URL' => 'postgres://u:p@host:5432/' }
      expect { described_class.safe_test_database_name(env) }.to raise_error(error)
    end

    it 'rejects a non-postgres URL scheme even when the database name is test-only' do
      env = { 'DATABASE_URL' => 'mysql://u:p@host:3306/app_test' }
      expect { described_class.safe_test_database_name(env) }
        .to raise_error(error, /postgres/)
    end

    it 'accepts a postgresql:// scheme' do
      env = { 'TEST_DATABASE_URL' => 'postgresql://u:p@host:5432/app_test' }
      expect(described_class.safe_test_database_name(env)).to eq('app_test')
    end
  end

  describe '.test_only?' do
    it 'accepts clearly test-only names' do
      expect(described_class.test_only?('chatwoot_test')).to be(true)
      expect(described_class.test_only?('myapp_test')).to be(true)
    end

    it 'rejects production, empty, and unsafe names' do
      expect(described_class.test_only?('chatwoot_production')).to be(false)
      expect(described_class.test_only?('chatwoot')).to be(false)
      expect(described_class.test_only?('')).to be(false)
      expect(described_class.test_only?('test; DROP TABLE users')).to be(false)
      expect(described_class.test_only?('prod_test')).to be(false)
    end
  end

  describe '.resolve!' do
    it 'is a no-op default outside the test environment (does not touch DATABASE_URL)' do
      env = { 'RAILS_ENV' => 'production', 'DATABASE_URL' => 'postgres://u:p@host/chatwoot_production' }
      expect(described_class.resolve!(env)).to eq('chatwoot_test')
      expect(env).to have_key('DATABASE_URL')
    end

    it 'clears a generic DATABASE_URL on name-based selection in test' do
      env = { 'RAILS_ENV' => 'test', 'POSTGRES_TEST_DATABASE' => 'chatwoot_test' }
      expect(described_class.resolve!(env)).to eq('chatwoot_test')
      expect(env).not_to have_key('DATABASE_URL')
    end

    it 'promotes a validated TEST_DATABASE_URL to DATABASE_URL so its host/creds win' do
      env = { 'RAILS_ENV' => 'test',
              'TEST_DATABASE_URL' => 'postgres://urluser:urlpass@urlhost:6543/app_test',
              'DATABASE_URL' => 'postgres://u:p@prodhost/chatwoot_production' }
      expect(described_class.resolve!(env)).to eq('app_test')
      expect(env['DATABASE_URL']).to eq('postgres://urluser:urlpass@urlhost:6543/app_test')
    end

    it 'keeps a validated safe generic DATABASE_URL in place for use as the connection' do
      env = { 'RAILS_ENV' => 'test',
              'DATABASE_URL' => 'postgres://urluser:urlpass@urlhost:6543/app_test' }
      expect(described_class.resolve!(env)).to eq('app_test')
      expect(env['DATABASE_URL']).to eq('postgres://urluser:urlpass@urlhost:6543/app_test')
    end
  end
end
