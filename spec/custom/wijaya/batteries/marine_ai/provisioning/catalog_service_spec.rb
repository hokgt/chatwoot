# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Provisioning::CatalogService do
  # chatwoot CONNECT flag returned by the has_database_privilege($1,$2,$3) probe.
  let(:chatwoot_connect_row) { { 'connect' => 'f' } }
  # When true, the chatwoot CONNECT probe raises so the service reports unknown.
  let(:chatwoot_connect_raises) { false }
  # Role memberships granted TO the login (must be empty after downgrade/revoke).
  let(:membership_rows) { [] }
  let(:conn) do
    c = instance_double(PG::Connection)
    allow(c).to receive(:exec) do |sql|
      instance_double(PG::Result, first: { 'ssl' => 't' }) if sql.include?('pg_stat_ssl')
    end
    allow(c).to receive(:exec_params) do |sql, _params = nil|
      if sql.include?('rolcanlogin')
        instance_double(PG::Result, first: {
                          'rolcanlogin' => 't', 'rolsuper' => 'f', 'rolcreaterole' => 'f',
                          'rolcreatedb' => 'f', 'rolreplication' => 'f', 'rolbypassrls' => 'f'
                        })
      elsif sql.include?('pg_auth_members')
        membership_rows # role_memberships maps over these rows
      elsif sql.include?('has_database_privilege') && sql.include?('$3')
        raise PG::Error, 'connect probe boom' if chatwoot_connect_raises

        instance_double(PG::Result, first: chatwoot_connect_row) # chatwoot CONNECT must be false
      elsif sql.include?('has_database_privilege')
        instance_double(PG::Result, first: { 'connect' => 't', 'create' => 'f', 'temporary' => 'f' })
      elsif sql.include?('information_schema.schemata')
        instance_double(PG::Result, ntuples: 1)
      elsif sql.include?('has_schema_privilege')
        instance_double(PG::Result, first: { 'usage' => 't', 'create' => 'f' })
      elsif sql.include?('has_table_privilege')
        instance_double(PG::Result, first: {
                          'total' => '5',
                          'select_all' => 't', 'select_any' => 't',
                          'insert_all' => 't', 'insert_any' => 't',
                          'update_all' => 't', 'update_any' => 't',
                          'delete_all' => 't', 'delete_any' => 't',
                          'truncate_any' => 'f'
                        })
      elsif sql.include?('has_function_privilege')
        instance_double(PG::Result, first: { 'total' => '2', 'execute_any' => 'f' })
      elsif sql.include?('has_sequence_privilege')
        instance_double(PG::Result, first: { 'total' => '1', 'usage_any' => 'f', 'select_any' => 'f', 'update_any' => 'f' })
      else
        instance_double(PG::Result, getvalue: '0')
      end
    end
    c
  end

  before do
    Marine::Provisioning::StateStore.write!(
      status: 'active', database_name: 'marine_erp', login_username: 'marine_app',
      owner_role: 'marine_erp_owner', privilege_level: 'writer'
    )
    allow(Marine::Provisioning::Connection).to receive(:with_admin_on).and_yield(conn)
  end

  it 'returns a structured privilege matrix without secrets or raw SQL' do
    matrix = described_class.new(actor_id: 1).call

    expect(matrix[:login_username]).to eq('marine_app')
    expect(matrix[:privilege_level]).to eq('writer')
    expect(matrix[:role]).to eq(
      can_login: true, superuser: false, create_role: false,
      create_db: false, replication: false, bypass_rls: false
    )
    expect(matrix[:database]).to include(connect: true, create: false, temporary: false)
    expect(matrix[:owned_objects]).to eq(0)

    serialized = matrix.to_s
    expect(serialized).not_to match(/password/i)
    expect(serialized).not_to include('has_table_privilege')
  end

  it 'reports whether the login can CONNECT to the existing Chatwoot database (must be false)' do
    matrix = described_class.new.call
    expect(matrix[:database][:chatwoot_connect]).to be(false)
    expect(matrix[:database][:chatwoot_connect_check_error]).to be(false)
  end

  context 'when the Chatwoot CONNECT probe itself errors' do
    let(:chatwoot_connect_raises) { true }

    it 'returns an explicit unknown (nil) with check_error rather than a fabricated boolean' do
      matrix = described_class.new.call
      expect(matrix[:database][:chatwoot_connect]).to be_nil
      expect(matrix[:database][:chatwoot_connect_check_error]).to be(true)
    end
  end

  it 'reports role memberships (empty for an exact writer) from the catalog' do
    expect(described_class.new.call[:memberships]).to eq(count: 0, roles: [])
  end

  context 'when the login still holds role memberships' do
    let(:membership_rows) { [{ 'granted_role' => 'reporting_ro' }] }

    it 'surfaces the lingering memberships with a count' do
      expect(described_class.new.call[:memberships]).to eq(count: 1, roles: ['reporting_ro'])
    end
  end

  it 'reports effective function and sequence privilege flags (false for an exact writer)' do
    matrix = described_class.new.call
    expect(matrix[:functions]).to include(execute_any: false, total: 2)
    expect(matrix[:sequences]).to include(usage_any: false, select_any: false, update_any: false, total: 1)
  end

  it 'distinguishes ALL vs ANY table coverage and reports the total table count' do
    tables = described_class.new.call[:tables]

    expect(tables[:total]).to eq(5)
    expect(tables[:select]).to eq(all: true, any: true)
    expect(tables[:truncate]).to eq(any: false)
  end

  it 'reports the effective SSL usage for the session and the configured mode' do
    ssl = described_class.new.call[:ssl]
    expect(ssl[:in_use]).to be(true)
    expect(ssl[:configured_mode]).to eq(Marine::Provisioning::Config.ssl_mode)
  end

  it 'raises NotProvisionedError when nothing is provisioned' do
    Marine::Provisioning::StateStore.reset!
    expect { described_class.new.call }.to raise_error(Marine::Provisioning::Errors::NotProvisionedError)
  end
end
