# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Provisioning::ProvisionService do
  # Fake PG connection. No real database is ever touched.
  let(:lock_acquired) { 't' }
  # Prior CONNECT posture on the Chatwoot DB, as read before hardening: whether the
  # datacl was default, whether PUBLIC held CONNECT, and whether the app role held a
  # DIRECT explicit CONNECT ACL entry.
  let(:acl_row) { { 'acl_default' => 'f', 'public_connect' => 't', 'app_connect' => 'f' } }
  # Records every exec'd SQL string in call order so ordering can be asserted.
  let(:executed) { [] }
  let(:conn) do
    c = instance_double(PG::Connection)
    allow(c).to receive(:exec) { |sql| executed << sql }
    allow(c).to receive(:quote_ident) { |n| %("#{n}") }
    allow(c).to receive(:escape_literal) { |s| "'#{s}'" }
    allow(c).to receive(:exec_params).and_return(
      instance_double(PG::Result, getvalue: lock_acquired, first: acl_row)
    )
    c
  end

  let(:service) do
    described_class.new(
      database_name: 'marine_erp',
      login_username: 'marine_app',
      password: 'a-strong-password-123',
      actor_id: 42
    )
  end

  before do
    allow(Marine::Provisioning::Connection).to receive(:with_admin).and_yield(conn)
    allow(Marine::Provisioning::Connection).to receive(:with_admin_on).and_yield(conn)
    allow(Marine::Provisioning::Connection).to receive(:app_connectivity_ok?).and_return(true)
  end

  describe '#call happy path' do
    it 'creates owner, login and database, then persists active non-secret state' do
      service.call

      expect(conn).to have_received(:exec).with(/CREATE ROLE "marine_erp_owner" NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS/)
      # The login role is created NOLOGIN with its password already set, then only
      # ALTER ROLE ... LOGIN activates it as the final PostgreSQL step.
      expect(conn).to have_received(:exec).with(/CREATE ROLE "marine_app" NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD/)
      expect(conn).to have_received(:exec).with('ALTER ROLE "marine_app" LOGIN')
      expect(conn).to have_received(:exec).with(/CREATE DATABASE "marine_erp" OWNER "marine_erp_owner"/)
      expect(conn).to have_received(:exec).with(/REVOKE CONNECT, TEMPORARY ON DATABASE "marine_erp" FROM PUBLIC/)
      expect(conn).to have_received(:exec).with(/GRANT CONNECT, CREATE ON DATABASE "marine_erp" TO "marine_app"/)
      expect(conn).to have_received(:exec).with('REVOKE ALL ON SCHEMA public FROM PUBLIC')

      state = Marine::Provisioning::StateStore.current
      expect(state['status']).to eq('active')
      expect(state['database_name']).to eq('marine_erp')
      expect(state['owner_role']).to eq('marine_erp_owner')
    end

    it 'returns only non-secret connection details (never the password or schema)' do
      details = service.call
      expect(details.keys).to contain_exactly(:host, :port, :database_name, :login_username, :ssl_mode)
      expect(details.values.map(&:to_s)).not_to include('a-strong-password-123')
    end

    it 'does NOT create or grant the marine_ai schema (the ERP creates and owns it)' do
      service.call

      expect(conn).not_to have_received(:exec).with(/CREATE SCHEMA/)
      expect(conn).not_to have_received(:exec).with(/ON SCHEMA "marine_ai"/)
    end

    it 'activates LOGIN only AFTER hardening Chatwoot and verifying app connectivity' do
      service.call

      alter_login_at = executed.index { |sql| sql == 'ALTER ROLE "marine_app" LOGIN' }
      chatwoot_revoke_at = executed.index { |sql| sql =~ /REVOKE CONNECT ON DATABASE .* FROM PUBLIC/ }
      commit_at = executed.index('COMMIT')

      expect(alter_login_at).to be > chatwoot_revoke_at
      expect(alter_login_at).to be > commit_at
      expect(Marine::Provisioning::Connection).to have_received(:app_connectivity_ok?)
    end

    it 'hardens the existing Chatwoot database ACL inside a transaction and verifies app connectivity' do
      chatwoot = Marine::Provisioning::Config.app_database
      service.call

      expect(conn).to have_received(:exec).with('BEGIN')
      expect(conn).to have_received(:exec).with(/REVOKE CONNECT ON DATABASE "#{chatwoot}" FROM PUBLIC/)
      expect(conn).to have_received(:exec).with(/GRANT CONNECT ON DATABASE "#{chatwoot}" TO/)
      expect(conn).to have_received(:exec).with('COMMIT')
      expect(Marine::Provisioning::Connection).to have_received(:app_connectivity_ok?)
    end

    it 'persists the marine_ai schema in the durable state' do
      service.call
      expect(Marine::Provisioning::StateStore.current['schema']).to eq('marine_ai')
    end
  end

  describe 'guards' do
    it 'rejects invalid identifiers before opening any connection' do
      bad = described_class.new(database_name: 'Bad-Name', login_username: 'marine_app', password: 'a-strong-password-123')
      expect { bad.call }.to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
      expect(Marine::Provisioning::Connection).not_to have_received(:with_admin)
    end

    it 'rejects a short password' do
      weak = described_class.new(database_name: 'marine_erp', login_username: 'marine_app', password: 'short')
      expect { weak.call }.to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
    end

    it 'rejects a database name identical to the login username (collision)' do
      collide = described_class.new(database_name: 'marine_same', login_username: 'marine_same', password: 'a-strong-password-123')
      expect { collide.call }.to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
      expect(Marine::Provisioning::Connection).not_to have_received(:with_admin)
    end

    it 'derives a distinct <=63-byte owner role for a 63-byte database name' do
      long_db = 'd' * 63
      svc = described_class.new(database_name: long_db, login_username: 'marine_app', password: 'a-strong-password-123')
      svc.call

      owner = Marine::Provisioning::StateStore.current['owner_role']
      expect(owner.bytesize).to be <= 63
      expect(owner).not_to eq(long_db)
      expect(owner).to match(/_o_[0-9a-f]{8}\z/)
    end

    it 'refuses to provision twice' do
      Marine::Provisioning::StateStore.write!(status: 'active', database_name: 'x', login_username: 'y')
      expect { service.call }.to raise_error(Marine::Provisioning::Errors::AlreadyProvisionedError)
    end

    context 'when the advisory lock is held' do
      let(:lock_acquired) { 'f' }

      it 'raises LockUnavailableError' do
        expect { service.call }.to raise_error(Marine::Provisioning::Errors::LockUnavailableError)
      end
    end
  end

  describe 'compensation' do
    before { allow(Marine::Provisioning::Connection).to receive(:app_connectivity_ok?).and_return(false) }

    it 'rolls back created objects and does not mark active when connectivity fails' do
      expect { service.call }.to raise_error(Marine::Provisioning::Errors::SanitizedError)

      expect(conn).to have_received(:exec).with(/DROP DATABASE IF EXISTS "marine_erp"/)
      expect(conn).to have_received(:exec).with(/DROP ROLE IF EXISTS "marine_app"/)
      expect(conn).to have_received(:exec).with(/DROP ROLE IF EXISTS "marine_erp_owner"/)
      expect(Marine::Provisioning::StateStore.current['status']).not_to eq('active')
    end

    context 'when PUBLIC did not hold CONNECT on Chatwoot beforehand' do
      let(:acl_row) { { 'acl_default' => 'f', 'public_connect' => 'f' } }

      it 'does not re-grant PUBLIC CONNECT during compensation (no posture loosening)' do
        chatwoot = Marine::Provisioning::Config.app_database
        expect { service.call }.to raise_error(Marine::Provisioning::Errors::SanitizedError)

        expect(conn).not_to have_received(:exec).with(/GRANT CONNECT ON DATABASE "#{chatwoot}" TO PUBLIC/)
      end
    end

    context 'when the app role held NO explicit CONNECT before hardening' do
      let(:acl_row) { { 'acl_default' => 'f', 'public_connect' => 't', 'app_connect' => 'f' } }

      it 'revokes the explicit app-role CONNECT it added (restores exact prior posture)' do
        chatwoot = Marine::Provisioning::Config.app_database
        expect { service.call }.to raise_error(Marine::Provisioning::Errors::SanitizedError)

        expect(conn).to have_received(:exec).with(/REVOKE CONNECT ON DATABASE "#{chatwoot}" FROM "[^"]+"/)
      end
    end

    context 'when the app role already held an explicit CONNECT before hardening' do
      let(:acl_row) { { 'acl_default' => 'f', 'public_connect' => 't', 'app_connect' => 't' } }

      it 'does NOT revoke the pre-existing app-role CONNECT during compensation' do
        chatwoot = Marine::Provisioning::Config.app_database
        app_role = Marine::Provisioning::Config.app_username
        expect { service.call }.to raise_error(Marine::Provisioning::Errors::SanitizedError)

        expect(conn).not_to have_received(:exec).with(%(REVOKE CONNECT ON DATABASE "#{chatwoot}" FROM "#{app_role}"))
      end
    end

    context 'when the GRANT fails after the REVOKE during hardening' do
      before do
        allow(Marine::Provisioning::Connection).to receive(:app_connectivity_ok?).and_return(true)
        chatwoot = Marine::Provisioning::Config.app_database
        allow(conn).to receive(:exec) do |sql|
          raise PG::Error, 'grant boom' if sql.include?(%(GRANT CONNECT ON DATABASE "#{chatwoot}"))
        end
      end

      it 'rolls back the hardening transaction and compensates without marking active' do
        expect { service.call }.to raise_error(Marine::Provisioning::Errors::SanitizedError)

        expect(conn).to have_received(:exec).with('ROLLBACK')
        expect(conn).to have_received(:exec).with(/DROP DATABASE IF EXISTS "marine_erp"/)
        expect(Marine::Provisioning::StateStore.current['status']).not_to eq('active')
      end
    end

    context 'when compensation itself fails' do
      before do
        allow(conn).to receive(:exec) do |sql|
          raise PG::Error, 'cleanup boom' if sql.start_with?('DROP DATABASE')
        end
      end

      it 'persists a sanitized needs_manual_cleanup state and raises ManualCleanupRequiredError' do
        expect { service.call }.to raise_error(Marine::Provisioning::Errors::ManualCleanupRequiredError)
        state = Marine::Provisioning::StateStore.current
        expect(state['status']).to eq('needs_manual_cleanup')
        expect(state.to_s).not_to include('a-strong-password-123')
      end
    end
  end
end
