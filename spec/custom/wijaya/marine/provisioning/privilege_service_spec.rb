# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Provisioning::PrivilegeService do
  # Owns-nothing count returned by the comprehensive verification query.
  let(:owned_count) { '0' }
  # rolcanlogin flag for the internal owner role pre-check.
  let(:owner_can_login) { 'f' }
  # Owner attribute row returned by ensure_owner_role! — least-privilege by default.
  let(:owner_row) do
    { 'rolcanlogin' => owner_can_login, 'rolsuper' => 'f', 'rolcreatedb' => 'f',
      'rolcreaterole' => 'f', 'rolreplication' => 'f', 'rolbypassrls' => 'f' }
  end
  # Role memberships granted TO the login, as rows for revoke_memberships to iterate.
  let(:membership_rows) { [] }
  let(:conn) do
    c = instance_double(PG::Connection)
    allow(c).to receive(:exec)
    allow(c).to receive(:quote_ident) { |n| %("#{n}") }
    allow(c).to receive(:exec_params) do |sql, _params = nil|
      case sql
      when /pg_try_advisory_lock/, /pg_advisory_unlock/ then instance_double(PG::Result, getvalue: 't')
      when /information_schema\.schemata/ then instance_double(PG::Result, ntuples: 1)
      when /pg_shdepend/ then instance_double(PG::Result, getvalue: owned_count) # verify owns-nothing
      when /pg_auth_members/ then membership_rows # revoke_memberships iterates these
      when /pg_roles/ then instance_double(PG::Result, first: owner_row)
      else instance_double(PG::Result, ntuples: 0, getvalue: '0', first: nil)
      end
    end
    c
  end

  before do
    Marine::Provisioning::StateStore.write!(
      status: 'active', database_name: 'marine_erp', login_username: 'marine_app',
      owner_role: 'marine_erp_owner', privilege_level: 'admin'
    )
    allow(Marine::Provisioning::Connection).to receive(:with_admin_on).and_yield(conn)
  end

  describe '#downgrade_to_writer!' do
    it 'runs inside a transaction: reassign, DROP OWNED, pin attributes, then grant writer-only DML' do
      described_class.new(actor_id: 1).downgrade_to_writer!

      expect(conn).to have_received(:exec).with('BEGIN')
      expect(conn).to have_received(:exec).with('REASSIGN OWNED BY "marine_app" TO "marine_erp_owner"')
      expect(conn).to have_received(:exec).with('DROP OWNED BY "marine_app"')
      expect(conn).to have_received(:exec)
        .with('ALTER ROLE "marine_app" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS')
      expect(conn).to have_received(:exec).with(/GRANT USAGE ON SCHEMA "marine_ai" TO "marine_app"/)
      expect(conn).to have_received(:exec)
        .with(/GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "marine_ai" TO "marine_app"/)
      expect(conn).to have_received(:exec).with('COMMIT')
      expect(Marine::Provisioning::StateStore.current['privilege_level']).to eq('writer')
    end

    it 're-hardens PUBLIC on the target database and public schema' do
      described_class.new.downgrade_to_writer!

      expect(conn).to have_received(:exec).with(/REVOKE CONNECT, TEMPORARY ON DATABASE "marine_erp" FROM PUBLIC/)
      expect(conn).to have_received(:exec).with('REVOKE ALL ON SCHEMA public FROM PUBLIC')
    end

    it 'never grants TRUNCATE or CREATE to the writer' do
      described_class.new.downgrade_to_writer!
      expect(conn).not_to have_received(:exec).with(/GRANT[^;]*TRUNCATE/)
      expect(conn).not_to have_received(:exec).with(/GRANT CREATE ON/)
    end

    it 'strips PUBLIC EXECUTE on marine_ai functions and procedures before granting the writer' do
      described_class.new.downgrade_to_writer!
      expect(conn).to have_received(:exec).with('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA "marine_ai" FROM PUBLIC')
      expect(conn).to have_received(:exec).with('REVOKE ALL ON ALL PROCEDURES IN SCHEMA "marine_ai" FROM PUBLIC')
    end

    it 'grants NO function or sequence privileges to the writer' do
      described_class.new.downgrade_to_writer!
      expect(conn).not_to have_received(:exec).with(/GRANT[^;]*ON ALL FUNCTIONS[^;]*TO "marine_app"/)
      expect(conn).not_to have_received(:exec).with(/GRANT[^;]*ON ALL SEQUENCES[^;]*TO "marine_app"/)
    end

    context 'when the login is a member of other roles' do
      let(:membership_rows) { [{ 'granted_role' => 'reporting_ro' }, { 'granted_role' => 'billing_rw' }] }

      it 'explicitly revokes every role membership (DROP OWNED does not)' do
        described_class.new.downgrade_to_writer!
        expect(conn).to have_received(:exec).with('REVOKE "reporting_ro" FROM "marine_app"')
        expect(conn).to have_received(:exec).with('REVOKE "billing_rw" FROM "marine_app"')
      end
    end

    context 'when the internal owner holds an elevated attribute out-of-band' do
      let(:owner_row) do
        { 'rolcanlogin' => 'f', 'rolsuper' => 'f', 'rolcreatedb' => 't',
          'rolcreaterole' => 'f', 'rolreplication' => 'f', 'rolbypassrls' => 'f' }
      end

      it 'fails closed before reassigning ownership' do
        expect { described_class.new.downgrade_to_writer! }
          .to raise_error(Marine::Provisioning::Errors::SanitizedError) { |e| expect(e.i18n_key).to eq('PROVISIONING.ERRORS.OWNER_ROLE_INVALID') }
        expect(conn).not_to have_received(:exec).with(/REASSIGN OWNED/)
      end
    end

    context 'when the durable state write fails after the DDL commits' do
      it 'raises StateSyncError (no rollback claim) even though the DDL committed' do
        allow(Marine::Provisioning::StateStore).to receive(:write!)
          .with(hash_including(privilege_level: 'writer')).and_raise(StandardError, 'installation config unavailable')

        expect { described_class.new.downgrade_to_writer! }
          .to raise_error(Marine::Provisioning::Errors::StateSyncError)
        expect(conn).to have_received(:exec).with('COMMIT')
        expect(Marine::Provisioning::StateStore.current['privilege_level']).to eq('admin')
      end
    end

    context 'when the login still owns objects afterwards' do
      let(:owned_count) { '3' }

      it 'fails with a sanitized downgrade-incomplete error and does not persist writer' do
        expect { described_class.new.downgrade_to_writer! }
          .to raise_error(Marine::Provisioning::Errors::SanitizedError) { |e| expect(e.i18n_key).to eq('PROVISIONING.ERRORS.DOWNGRADE_INCOMPLETE') }
        expect(Marine::Provisioning::StateStore.current['privilege_level']).to eq('admin')
      end
    end

    context 'when the owner role can log in' do
      let(:owner_can_login) { 't' }

      it 'refuses to reassign ownership to a login-capable role' do
        expect { described_class.new.downgrade_to_writer! }
          .to raise_error(Marine::Provisioning::Errors::SanitizedError) { |e| expect(e.i18n_key).to eq('PROVISIONING.ERRORS.OWNER_ROLE_INVALID') }
        expect(conn).not_to have_received(:exec).with(/REASSIGN OWNED/)
      end
    end

    context 'when the target schema is missing' do
      let(:conn) do
        c = instance_double(PG::Connection)
        allow(c).to receive(:exec)
        allow(c).to receive(:quote_ident) { |n| %("#{n}") }
        allow(c).to receive(:exec_params) do |sql, _p = nil|
          case sql
          when /pg_try_advisory_lock/, /pg_advisory_unlock/ then instance_double(PG::Result, getvalue: 't')
          when /information_schema\.schemata/ then instance_double(PG::Result, ntuples: 0)
          when /pg_roles/ then instance_double(PG::Result, first: { 'rolcanlogin' => 'f' })
          else instance_double(PG::Result, ntuples: 0, getvalue: '0', first: nil)
          end
        end
        c
      end

      it 'fails with a sanitized schema-missing error' do
        expect { described_class.new.downgrade_to_writer! }
          .to raise_error(Marine::Provisioning::Errors::SanitizedError) { |e| expect(e.i18n_key).to eq('PROVISIONING.ERRORS.SCHEMA_MISSING') }
      end
    end

    context 'when already downgraded to writer' do
      before { Marine::Provisioning::StateStore.write!(privilege_level: 'writer') }

      it 'rejects the invalid transition under the lock without running any DDL' do
        expect { described_class.new.downgrade_to_writer! }
          .to raise_error(Marine::Provisioning::Errors::InvalidPrivilegeTransitionError)
        # The lock is acquired first (opening a connection), but the transition is
        # guarded BEFORE any mutation, so no reassignment/DDL is ever issued and the
        # advisory lock is released.
        expect(conn).not_to have_received(:exec).with(/REASSIGN OWNED/)
        expect(conn).not_to have_received(:exec).with('BEGIN')
        expect(conn).to have_received(:exec_params).with(/pg_advisory_unlock/, anything)
      end
    end

    context 'when the login has been revoked (NOLOGIN)' do
      before { Marine::Provisioning::StateStore.write!(privilege_level: 'revoked') }

      it 'refuses to silently re-grant login by downgrading' do
        expect { described_class.new.downgrade_to_writer! }
          .to raise_error(Marine::Provisioning::Errors::InvalidPrivilegeTransitionError)
      end
    end
  end

  describe '#revoke_all!' do
    it 'reassigns owned objects, DROP OWNED, and pins the role to NOLOGIN least-privilege' do
      described_class.new.revoke_all!

      expect(conn).to have_received(:exec).with('REASSIGN OWNED BY "marine_app" TO "marine_erp_owner"')
      expect(conn).to have_received(:exec).with('DROP OWNED BY "marine_app"')
      expect(conn).to have_received(:exec)
        .with('ALTER ROLE "marine_app" NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS')
      expect(Marine::Provisioning::StateStore.current['privilege_level']).to eq('revoked')
    end

    it 'never drops the database, schema, tables or data' do
      described_class.new.revoke_all!
      expect(conn).not_to have_received(:exec).with(/DROP DATABASE/)
      expect(conn).not_to have_received(:exec).with(/DROP SCHEMA/)
      expect(conn).not_to have_received(:exec).with(/DROP TABLE/)
      expect(conn).not_to have_received(:exec).with(/DELETE FROM/)
    end

    context 'when the login is a member of other roles' do
      let(:membership_rows) { [{ 'granted_role' => 'reporting_ro' }] }

      it 'revokes every role membership before setting NOLOGIN' do
        described_class.new.revoke_all!
        expect(conn).to have_received(:exec).with('REVOKE "reporting_ro" FROM "marine_app"')
      end
    end

    context 'when already revoked' do
      before { Marine::Provisioning::StateStore.write!(privilege_level: 'revoked') }

      it 'is idempotent and still succeeds' do
        expect { described_class.new.revoke_all! }.not_to raise_error
        expect(Marine::Provisioning::StateStore.current['privilege_level']).to eq('revoked')
      end
    end
  end

  describe 'when not provisioned' do
    before { Marine::Provisioning::StateStore.reset! }

    it 'raises NotProvisionedError' do
      expect { described_class.new.revoke_all! }.to raise_error(Marine::Provisioning::Errors::NotProvisionedError)
    end
  end
end
