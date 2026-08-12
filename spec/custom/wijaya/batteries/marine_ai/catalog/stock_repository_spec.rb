# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::StockRepository, type: :model do
  subject(:repository) { described_class.new }

  # Connection is always stubbed. By contract a raw numeric stock quantity NEVER crosses
  # the PostgreSQL boundary, so every stubbed row carries only the binary 'status' string —
  # never a number — and we assert the SQL projects only that status field.
  let(:captured) { [] }
  let(:stubbed_rows) { [{ 'status' => 'empty' }] }

  before do
    allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
    allow(Marine::Catalog::Config).to receive(:schema).and_return('marine_ai')
    allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
      captured << { sql: sql, params: params }
      stubbed_rows
    end
  end

  describe '#status_for' do
    context 'with a blank child code' do
      it 'returns :empty without touching the database' do
        expect(repository.status_for('')).to eq(:empty)
        expect(repository.status_for(nil)).to eq(:empty)
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end

    it 'sends SQL that queries only marine_ai.bin and projects only a binary status field' do
      repository.status_for('CHILD-1')
      sql = captured.last[:sql]

      expect(captured.last[:params]).to eq(['CHILD-1'])
      expect(sql).to include("CASE WHEN COALESCE(SUM(actual_qty), 0) > 0 THEN 'available' ELSE 'empty' END AS status")
      expect(sql).to include('FROM marine_ai.bin')
      expect(sql).to include('WHERE item_code = $1')

      # The projected columns are status ONLY — no numeric/quantity/warehouse leakage.
      select_clause = sql.split(/\bFROM\b/i).first
      expect(select_clause).to include('AS status')
      expect(select_clause).not_to include('projected_qty')
      expect(select_clause).not_to include('reserved_qty')
      expect(select_clause).not_to include('warehouse')
    end

    context 'when the database reports available' do
      let(:stubbed_rows) { [{ 'status' => 'available' }] }

      it 'maps to :available' do
        expect(repository.status_for('CHILD-1')).to eq(:available)
      end
    end

    context 'when the database reports empty' do
      let(:stubbed_rows) { [{ 'status' => 'empty' }] }

      it 'maps to :empty' do
        expect(repository.status_for('CHILD-1')).to eq(:empty)
      end
    end

    context 'when the status is unexpected' do
      let(:stubbed_rows) { [{ 'status' => 'unknown' }] }

      it 'fails closed with CatalogUnavailableError' do
        expect { repository.status_for('CHILD-1') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
      end
    end

    context 'when no row is returned' do
      let(:stubbed_rows) { [] }

      it 'fails closed with CatalogUnavailableError' do
        expect { repository.status_for('CHILD-1') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
      end
    end

    context 'when the catalog is not configured' do
      it 'fails closed with CatalogUnavailableError' do
        allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
        expect { repository.status_for('CHILD-1') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end
  end
end
