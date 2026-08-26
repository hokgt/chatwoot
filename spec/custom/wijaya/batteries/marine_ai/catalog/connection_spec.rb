# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::Connection, type: :model do
  # PG is always stubbed: no live database is ever touched. `conn` records the order
  # of the session SET commands and the SELECT so we can assert read-only setup happens
  # before the query.
  let(:conn) { instance_double(PG::Connection) }
  let(:result) { instance_double(PG::Result) }
  let(:calls) { [] }

  before do
    allow(Marine::Catalog::Config).to receive(:connection_params)
      .and_return(host: 'h', dbname: 'd', user: 'u', password: 'secret-pw')
    allow(PG).to receive(:connect).and_return(conn)
    allow(conn).to receive(:exec) { |sql| calls << [:exec, sql] }
    allow(conn).to receive(:exec_params) do |sql, _params|
      calls << [:exec_params, sql]
      result
    end
    allow(conn).to receive(:close)
    allow(result).to receive(:to_a).and_return([{ 'x' => 1 }])
  end

  describe '.select validation (SELECT-only, single statement)' do
    non_selects = [
      'UPDATE marine_ai.item SET item_name = $1',
      'DELETE FROM marine_ai.item',
      'INSERT INTO marine_ai.item (item_code) VALUES ($1)',
      'DROP TABLE marine_ai.item',
      'ALTER TABLE marine_ai.item ADD COLUMN x int',
      'WITH t AS (SELECT 1) SELECT * FROM t',
      '   ',
      ''
    ]

    non_selects.each do |sql|
      it "rejects non-SELECT SQL (#{sql.strip[0, 24].inspect}) without connecting" do
        expect { described_class.select(sql) }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
        expect(PG).not_to have_received(:connect)
        expect(conn).not_to have_received(:exec_params)
      end
    end

    multi_statements = [
      'SELECT 1; DROP TABLE marine_ai.item',
      'SELECT 1;',
      'SELECT 1 FROM marine_ai.item; SELECT 2'
    ]

    multi_statements.each do |sql|
      it "rejects multi-statement SQL (#{sql.inspect}) without connecting" do
        expect { described_class.select(sql) }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
        expect(PG).not_to have_received(:connect)
        expect(conn).not_to have_received(:exec_params)
      end
    end

    it 'does not expose the rejected SQL in the raised error' do
      described_class.select('DROP TABLE secret_marine_table')
    rescue Marine::Catalog::Errors::CatalogUnavailableError => e
      expect(e.message).not_to include('secret_marine_table')
      expect(e.message).not_to include('DROP')
    end

    it 'accepts a single SELECT with leading whitespace/newlines' do
      expect { described_class.select("\n   SELECT 1") }.not_to raise_error
      expect(PG).to have_received(:connect)
    end
  end

  describe '.select happy path' do
    it 'returns row hashes from a valid parameterized SELECT' do
      expect(described_class.select('SELECT 1', ['a'])).to eq([{ 'x' => 1 }])
      expect(conn).to have_received(:exec_params).with('SELECT 1', ['a'])
    end

    it 'applies the read-only session before running the SELECT' do
      described_class.select('SELECT 1')

      read_only_idx = calls.index { |kind, sql| kind == :exec && sql.include?('default_transaction_read_only') }
      select_idx = calls.index { |kind, _sql| kind == :exec_params }

      expect(read_only_idx).not_to be_nil
      expect(select_idx).not_to be_nil
      expect(read_only_idx).to be < select_idx
    end

    it 'closes the connection after a successful select' do
      described_class.select('SELECT 1')
      expect(conn).to have_received(:close)
    end

    it 'does not leak or mask a successful result when connection close fails' do
      allow(conn).to receive(:close).and_raise(PG::Error.new('close secret detail'))
      expect(described_class.select('SELECT 1')).to eq([{ 'x' => 1 }])
    end
  end

  describe '.select when read-only session setup fails' do
    before do
      allow(conn).to receive(:exec).and_raise(PG::Error.new('read-only failed for SELECT secret'))
    end

    it 'closes the connection so it cannot leak, and never runs the SELECT' do
      expect { described_class.select('SELECT 1') }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
      expect(conn).to have_received(:close).once
      expect(conn).not_to have_received(:exec_params)
    end

    it 'fails closed with a sanitized error that does not leak the PG detail' do
      described_class.select('SELECT 1')
    rescue Marine::Catalog::Errors::CatalogUnavailableError => e
      expect(e.message).not_to include('read-only failed')
      expect(e.message).not_to include('secret')
    end
  end

  describe '.select when the SELECT itself raises' do
    before do
      allow(conn).to receive(:exec_params).and_raise(PG::Error.new('boom for SELECT secret'))
    end

    it 'fails closed with a sanitized error and still closes the connection' do
      expect { described_class.select('SELECT 1') }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError) do |e|
          expect(e.message).not_to include('boom')
          expect(e.message).not_to include('secret')
        end
      expect(conn).to have_received(:close)
    end
  end

  # D8 — bounded retry for TRANSIENT read-only connectivity blips. A single fresh SELECT
  # attempt is made when a connection is lost/unsendable; every other failure still fails
  # closed immediately. RED against pre-D8 code: it made exactly one attempt and never
  # retried, so the "two attempts / success on retry" expectations below could not pass.
  describe '.select bounded transient-connectivity retry (D8)' do
    it 'retries once on a transient error and succeeds — exactly two attempts' do
      attempt = 0
      allow(conn).to receive(:exec_params) do |sql, _params|
        attempt += 1
        raise PG::UnableToSend, 'unable to send data to server: SELECT secret' if attempt == 1

        calls << [:exec_params, sql]
        result
      end

      expect(described_class.select('SELECT 1')).to eq([{ 'x' => 1 }])
      expect(attempt).to eq(2)
      expect(PG).to have_received(:connect).twice
      expect(conn).to have_received(:close).twice
    end

    it 'retries at most once, then fails closed when the transient error persists — two attempts' do
      allow(conn).to receive(:exec_params).and_raise(PG::ConnectionBad, 'connection reset SELECT secret')

      expect { described_class.select('SELECT 1') }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
      expect(PG).to have_received(:connect).twice
      expect(conn).to have_received(:close).twice
    end

    it 'opens a fresh OWNED connection for the retry and discards only the failed one' do
      conn2 = instance_double(PG::Connection)
      allow(conn2).to receive(:exec)
      allow(conn2).to receive(:exec_params) { |sql, _p| (calls << [:exec_params, sql]) && result }
      allow(conn2).to receive(:close)
      allow(PG).to receive(:connect).and_return(conn, conn2)
      allow(conn).to receive(:exec_params).and_raise(PG::ConnectionBad, 'reset')

      expect(described_class.select('SELECT 1')).to eq([{ 'x' => 1 }])
      expect(conn).to have_received(:close)         # failed connection discarded
      expect(conn2).to have_received(:exec_params)  # retry ran on the fresh connection
      expect(conn2).to have_received(:close)
    end

    nonretryable = {
      'a statement timeout / query canceled' => -> { PG::QueryCanceled.new('canceling statement due to statement timeout') },
      'a permission error' => -> { PG::InsufficientPrivilege.new('permission denied for table item') },
      'a syntax error' => -> { PG::SyntaxError.new('syntax error at or near SELECT') },
      'a generic server error' => -> { PG::Error.new('boom SELECT secret') }
    }

    nonretryable.each do |label, builder|
      it "does NOT retry #{label} — single attempt, fails closed" do
        allow(conn).to receive(:exec_params).and_raise(builder.call)

        expect { described_class.select('SELECT 1') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
        expect(PG).to have_received(:connect).once
      end
    end

    it 'does NOT retry a config-level CatalogError (e.g. missing password) — single attempt' do
      allow(described_class).to receive(:open).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)

      expect { described_class.select('SELECT 1') }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
      expect(described_class).to have_received(:open).once
    end

    it 'only ever re-runs an idempotent SELECT — no non-SELECT statement is issued on retry' do
      attempt = 0
      allow(conn).to receive(:exec_params) do |sql, _p|
        attempt += 1
        raise PG::ConnectionBad, 'reset' if attempt == 1

        calls << [:exec_params, sql]
        result
      end

      described_class.select('SELECT 1')
      issued = calls.filter_map { |kind, sql| sql if kind == :exec_params }
      expect(issued).to all(match(/\ASELECT/i))
    end

    it 'gives each call its OWN retry budget — retry state is not shared across calls' do
      allow(conn).to receive(:exec_params).and_raise(PG::ConnectionBad, 'reset')
      expect { described_class.select('SELECT 1') }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)

      attempt = 0
      allow(conn).to receive(:exec_params) do |sql, _p|
        attempt += 1
        raise PG::ConnectionBad, 'reset' if attempt == 1

        calls << [:exec_params, sql]
        result
      end
      expect(described_class.select('SELECT 1')).to eq([{ 'x' => 1 }])
      expect(attempt).to eq(2)
    end

    it 'logs a secret-safe WARNING (operation + error class + retry count only) on retry' do
      logged = []
      allow(Rails.logger).to receive(:warn) { |m| logged << m }
      attempt = 0
      allow(conn).to receive(:exec_params) do |sql, _p|
        attempt += 1
        raise PG::ConnectionBad, 'connection reset while running SELECT item_code secret' if attempt == 1

        calls << [:exec_params, sql]
        result
      end

      described_class.select('SELECT item_code FROM secret_table WHERE x = $1', ['pw'])

      expect(logged.size).to eq(1)
      payload = JSON.parse(logged.first)
      expect(payload).to include('tag' => 'marine.catalog.retry', 'operation' => 'select',
                                 'error_class' => 'PG::ConnectionBad', 'retry' => 1)
      expect(logged.first).not_to include('secret')
      expect(logged.first).not_to include('secret_table')
      expect(logged.first).not_to include('item_code')
    end

    # The retry lives in the single shared Connection seam, so it benefits every repository
    # — and therefore both the inbox and Playground paths, which share those repositories.
    it 'the retry benefits every repository through the shared Connection seam' do
      allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
      allow(Marine::Catalog::Config).to receive(:qualified_table).and_return('marine_ai.item')
      attempt = 0
      allow(conn).to receive(:exec_params) do |_sql, _p|
        attempt += 1
        raise PG::ConnectionBad, 'reset' if attempt == 1

        result
      end
      allow(result).to receive(:to_a).and_return([{ 'code' => 'FAM-1' }])

      expect(Marine::Catalog::ProductFamilyRepository.new.exists?('FAM-1')).to be(true)
      expect(attempt).to eq(2)
    end
  end
end
