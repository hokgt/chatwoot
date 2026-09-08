# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::PriceRepository, type: :model do
  subject(:repository) { described_class.new }

  # Connection is always stubbed; we assert the exact policy SQL semantics and bind
  # params. Prices are never resolved by picking a first row, and never fall back to any
  # price list other than 'User Price'.
  let(:captured) { [] }
  let(:stubbed_rows) { [] }

  before do
    allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
    allow(Marine::Catalog::Config).to receive(:schema).and_return('marine_ai')
    allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
      captured << { sql: sql, params: params }
      stubbed_rows
    end
  end

  describe '#price_for' do
    context 'with a blank child code' do
      it 'returns unavailable without touching the database' do
        expect(repository.price_for('')).to eq(status: :unavailable)
        expect(repository.price_for(nil)).to eq(status: :unavailable)
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end

    context 'when exactly one distinct qualifying tuple exists' do
      let(:stubbed_rows) { [{ 'price_list_rate' => '10.00', 'currency' => 'USD', 'uom' => 'Nos' }] }

      it 'returns the single available price and binds the child + User Price policy' do
        result = repository.price_for('CHILD-1')
        expect(result).to eq(status: :available, price_list_rate: '10.00', currency: 'USD', uom: 'Nos')

        call = captured.last
        expect(call[:params]).to eq(['CHILD-1', 'User Price'])
        expect(call[:params][1]).to eq(described_class::USER_PRICE_LIST)
      end

      it 'enforces the User Price / general / selling / date / enabled-list contract in fixed SQL' do
        repository.price_for('CHILD-1')
        sql = captured.last[:sql]

        expect(sql).to include('SELECT DISTINCT')
        expect(sql).to include('ip.price_list_rate AS price_list_rate')
        expect(sql).to include('ip.currency AS currency')
        expect(sql).to include('ip.uom AS uom')
        expect(sql).to include('FROM marine_ai.item_price ip')
        expect(sql).to include('JOIN marine_ai.price_list pl ON pl.name = ip.price_list')
        expect(sql).to include('ip.item_code = $1')
        expect(sql).to include('ip.price_list = $2')
        expect(sql).to include('ip.selling = true')
        expect(sql).to include('ip.customer IS NULL OR ip.customer = \'\'')
        expect(sql).to include('ip.valid_from <= CURRENT_DATE')
        expect(sql).to include('ip.valid_upto IS NULL OR ip.valid_upto >= CURRENT_DATE')
        expect(sql).to include('pl.enabled = true')
        expect(sql).to include('pl.selling = true')
        expect(sql).to include('LIMIT 2')
      end

      it 'selects only the three allowlisted output columns (no other item_price fields)' do
        repository.price_for('CHILD-1')
        select_clause = captured.last[:sql].split(/\bFROM\b/i).first
        expect(select_clause).not_to include('buying')
        expect(select_clause).not_to include('customer')
        expect(select_clause).not_to include('valid_from')
      end
    end

    context 'when the single qualifying tuple is missing price_list_rate' do
      let(:stubbed_rows) { [{ 'price_list_rate' => nil, 'currency' => 'USD', 'uom' => 'Nos' }] }

      it 'fails closed as unavailable and is never reported available' do
        expect(repository.price_for('CHILD-1')).to eq(status: :unavailable)
      end
    end

    context 'when the single qualifying tuple has a blank currency' do
      let(:stubbed_rows) { [{ 'price_list_rate' => '10.00', 'currency' => '', 'uom' => 'Nos' }] }

      it 'fails closed as unavailable and is never reported available' do
        expect(repository.price_for('CHILD-1')).to eq(status: :unavailable)
      end
    end

    context 'when the single qualifying tuple is missing uom' do
      let(:stubbed_rows) { [{ 'price_list_rate' => '10.00', 'currency' => 'USD', 'uom' => nil }] }

      it 'fails closed as unavailable and is never reported available' do
        expect(repository.price_for('CHILD-1')).to eq(status: :unavailable)
      end
    end

    context 'when no qualifying tuple exists' do
      let(:stubbed_rows) { [] }

      it 'returns unavailable and never falls back to another price list' do
        expect(repository.price_for('CHILD-1')).to eq(status: :unavailable)
      end
    end

    context 'when two or more distinct tuples exist' do
      let(:stubbed_rows) do
        [
          { 'price_list_rate' => '10.00', 'currency' => 'USD', 'uom' => 'Nos' },
          { 'price_list_rate' => '12.00', 'currency' => 'USD', 'uom' => 'Nos' }
        ]
      end

      it 'fails closed as a conflict and never picks the first tuple' do
        expect(repository.price_for('CHILD-1')).to eq(status: :conflict)
      end
    end

    context 'when the catalog is not configured' do
      it 'fails closed with CatalogUnavailableError' do
        allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
        expect { repository.price_for('CHILD-1') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end
  end
end
