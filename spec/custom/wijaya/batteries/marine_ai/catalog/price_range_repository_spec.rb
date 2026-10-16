# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::PriceRangeRepository, type: :model do
  subject(:repository) { described_class.new }

  # Connection is always stubbed; we assert the exact policy SQL semantics and bind params. The
  # range is computed only when EVERY active variant holds exactly one qualifying User Price tuple
  # and all variants share a single currency and UOM; anything else fails closed.
  let(:captured) { [] }
  let(:stubbed_rows) { [] }

  before do
    allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
    allow(Marine::Catalog::Config).to receive(:schema).and_return('marine_ai')
    allow(Marine::Catalog::Config).to receive(:qualified_table).and_return('marine_ai.item')
    allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
      captured << { sql: sql, params: params }
      stubbed_rows
    end
  end

  # A genuine qualifying tuple row: the LEFT JOIN matched a real item_price row, so the 'matched'
  # marker is present (TRUE) — regardless of whether the rate itself is NULL.
  def row(code, rate, currency = 'IDR', uom = 'yard')
    { 'item_code' => code, 'price_list_rate' => rate, 'currency' => currency, 'uom' => uom, 'matched' => true }
  end

  # A LEFT JOIN miss: no qualifying price for the active variant, so every joined column — including
  # the 'matched' marker — is NULL.
  def join_miss(code)
    { 'item_code' => code, 'price_list_rate' => nil, 'currency' => nil, 'uom' => nil, 'matched' => nil }
  end

  describe '#range_for' do
    context 'with a blank family code' do
      it 'returns unavailable without touching the database' do
        expect(repository.range_for('')).to eq(status: :unavailable)
        expect(repository.range_for(nil)).to eq(status: :unavailable)
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end

    context 'when every active variant holds exactly one qualifying tuple' do
      let(:stubbed_rows) { [row('BD-1', '12500'), row('BD-2', '45000'), row('BD-3', '30000')] }

      it 'returns the exact min/max range with the shared currency and UOM' do
        expect(repository.range_for('FAM-1')).to eq(
          status: :available, min: '12500', max: '45000', currency: 'IDR', uom: 'yard'
        )
      end

      it 'binds the family code and the fixed User Price policy, and never any other price list' do
        repository.range_for('FAM-1')
        call = captured.last
        expect(call[:params]).to eq(['FAM-1', 'User Price'])
        expect(call[:params][1]).to eq(described_class::USER_PRICE_LIST)
      end

      it 'enforces the SAME User Price / general / selling / date / enabled-list contract the exact lookup uses' do
        repository.range_for('FAM-1')
        sql = captured.last[:sql]

        expect(sql).to include('SELECT DISTINCT')
        expect(sql).to include('FROM marine_ai.item_price ip')
        expect(sql).to include('JOIN marine_ai.price_list pl ON pl.name = ip.price_list')
        expect(sql).to include('ip.price_list = $2')
        expect(sql).to include('ip.selling = true')
        expect(sql).to include('ip.customer IS NULL OR ip.customer = \'\'')
        expect(sql).to include('ip.valid_from <= CURRENT_DATE')
        expect(sql).to include('ip.valid_upto IS NULL OR ip.valid_upto >= CURRENT_DATE')
        expect(sql).to include('pl.enabled = true')
        expect(sql).to include('pl.selling = true')
        # A constant TRUE match marker rides along on every qualifying tuple and is exposed by the
        # outer SELECT, so a join miss (marker nil) is distinguishable from a genuine NULL-rate tuple.
        expect(sql).to include('TRUE AS matched')
        expect(sql).to include('q.matched AS matched')
        # Active variants are kept via a LEFT JOIN (a missing price surfaces, never a dropped variant),
        # joined on item_code ALONE.
        expect(sql).to include('FROM marine_ai.item i')
        expect(sql).to include('LEFT JOIN')
        expect(sql).to include('q.item_code = i.item_code')
        expect(sql).to include('i.variant_of = $1')
        expect(sql).to include('i.disabled = false')
      end

      it 'applies NO range-only restriction the exact PriceRepository lookup lacks (no packing / currency-match / stock-UOM)' do
        repository.range_for('FAM-1')
        sql = captured.last[:sql]

        # The three restrictions that would make the range CLEANER than the exact follow-up must be gone,
        # so any tuple the exact lookup would see reaches the range too (and an extra one becomes a conflict).
        expect(sql).not_to include('packing_unit')
        expect(sql).not_to include('ip.currency = pl.currency')
        expect(sql).not_to include('i.stock_uom')
      end

      it 'returns exact decimal strings, never a Float' do
        result = repository.range_for('FAM-1')
        expect(result[:min]).to be_a(String)
        expect(result[:max]).to be_a(String)
      end
    end

    context 'with duplicate identical qualifying rows for a variant' do
      let(:stubbed_rows) { [row('BD-1', '12500'), row('BD-1', '12500'), row('BD-2', '45000')] }

      it 'collapses the identical rows to one tuple and still computes the range' do
        expect(repository.range_for('FAM-1')).to eq(
          status: :available, min: '12500', max: '45000', currency: 'IDR', uom: 'yard'
        )
      end
    end

    context 'when an active variant has no qualifying price (LEFT JOIN nulls, marker absent)' do
      let(:stubbed_rows) { [row('BD-1', '12500'), join_miss('BD-2')] }

      it 'fails closed to unavailable — a missing variant is never silently dropped' do
        expect(repository.range_for('FAM-1')).to eq(status: :unavailable)
      end
    end

    context 'when a variant carries a single matched qualifying tuple with a NULL rate' do
      # A real qualifying item_price row can hold a NULL price_list_rate. It is a MATCHED tuple
      # (marker present), distinct from a join miss (marker nil), and must not be conflated with one.
      # Alone it fails the exact positive-amount validation downstream, exactly as
      # PriceRepository#price_for reports a lone blank-rate row as :unavailable.
      let(:stubbed_rows) { [row('BD-1', '12500'), row('BD-2', nil)] }

      it 'fails closed to unavailable after validation, matching exact pricing' do
        expect(repository.range_for('FAM-1')).to eq(status: :unavailable)
      end
    end

    context 'when a variant carries a matched NULL-rate tuple alongside a valid tuple' do
      # Two distinct matched tuples for one variant — a NULL-rate row and a priced row — is a
      # per-variant conflict, exactly as PriceRepository#price_for sees two distinct DISTINCT rows and
      # returns :conflict. The NULL-rate tuple must NOT be filtered away (that would let the range be
      # cleaner than the exact follow-up for the same variant).
      let(:stubbed_rows) { [row('BD-1', nil), row('BD-1', '13000'), row('BD-2', '45000')] }

      it 'fails closed to a conflict, matching exact pricing' do
        expect(repository.range_for('FAM-1')).to eq(status: :conflict)
      end
    end

    context 'when a single variant carries two distinct qualifying tuples' do
      let(:stubbed_rows) { [row('BD-1', '12500'), row('BD-1', '13000'), row('BD-2', '45000')] }

      it 'fails closed to a conflict — never picks a first tuple' do
        expect(repository.range_for('FAM-1')).to eq(status: :conflict)
      end
    end

    context 'with an extra qualifying tuple the removed range-only filters would have dropped' do
      # Before the policy match, the packing-unit / currency-match / stock-UOM restrictions could
      # silently discard one of a variant's qualifying rows, letting the range report a single clean
      # amount for a variant the exact lookup would call ambiguous. With those filters gone the extra
      # tuple now reaches the summarizer and the variant is a conflict — the range is never cleaner
      # than the exact follow-up for the same variant.
      let(:stubbed_rows) { [row('BD-1', '12500'), row('BD-1', '18000'), row('BD-2', '45000')] }

      it 'fails closed to a conflict instead of filtering the extra tuple away' do
        expect(repository.range_for('FAM-1')).to eq(status: :conflict)
      end
    end

    context 'with a variant carrying tuples in more than one UOM (previously masked by the stock-UOM join)' do
      let(:stubbed_rows) { [row('BD-1', '12500', 'IDR', 'yard'), row('BD-1', '12500', 'IDR', 'meter'), row('BD-2', '45000')] }

      it 'fails closed to a conflict — a per-variant multi-UOM tuple is no longer join-filtered' do
        expect(repository.range_for('FAM-1')).to eq(status: :conflict)
      end
    end

    context 'with a heterogeneous currency across variants' do
      let(:stubbed_rows) { [row('BD-1', '12500', 'IDR'), row('BD-2', '45000', 'USD')] }

      it 'fails closed to a conflict' do
        expect(repository.range_for('FAM-1')).to eq(status: :conflict)
      end
    end

    context 'with a heterogeneous UOM across variants' do
      let(:stubbed_rows) { [row('BD-1', '12500', 'IDR', 'yard'), row('BD-2', '45000', 'IDR', 'meter')] }

      it 'fails closed to a conflict' do
        expect(repository.range_for('FAM-1')).to eq(status: :conflict)
      end
    end

    context 'with an invalid or non-positive amount' do
      it 'fails closed to unavailable for a zero amount' do
        allow(Marine::Catalog::Connection).to receive(:select).and_return([row('BD-1', '0'), row('BD-2', '45000')])
        expect(repository.range_for('FAM-1')).to eq(status: :unavailable)
      end

      it 'fails closed to unavailable for a negative amount' do
        allow(Marine::Catalog::Connection).to receive(:select).and_return([row('BD-1', '-5'), row('BD-2', '45000')])
        expect(repository.range_for('FAM-1')).to eq(status: :unavailable)
      end

      it 'fails closed to unavailable for a non-decimal amount' do
        allow(Marine::Catalog::Connection).to receive(:select).and_return([row('BD-1', 'abc'), row('BD-2', '45000')])
        expect(repository.range_for('FAM-1')).to eq(status: :unavailable)
      end
    end

    context 'when the amounts are equal (including different decimal scale)' do
      it 'renders one amount for two variants at the same price' do
        allow(Marine::Catalog::Connection).to receive(:select).and_return([row('BD-1', '12500'), row('BD-2', '12500')])
        expect(repository.range_for('FAM-1')).to eq(
          status: :available, min: '12500', max: '12500', currency: 'IDR', uom: 'yard'
        )
      end

      it 'treats numerically equal amounts of different scale as a single amount' do
        allow(Marine::Catalog::Connection).to receive(:select).and_return([row('BD-1', '12500'), row('BD-2', '12500.00')])
        result = repository.range_for('FAM-1')
        expect(result[:status]).to eq(:available)
        expect(result[:min]).to eq(result[:max])
      end
    end

    context 'when no active variant exists' do
      let(:stubbed_rows) { [] }

      it 'fails closed to unavailable' do
        expect(repository.range_for('FAM-1')).to eq(status: :unavailable)
      end
    end

    context 'when the catalog is not configured' do
      it 'fails closed with CatalogUnavailableError and never queries' do
        allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)
        expect { repository.range_for('FAM-1') }
          .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
        expect(Marine::Catalog::Connection).not_to have_received(:select)
      end
    end
  end
end
