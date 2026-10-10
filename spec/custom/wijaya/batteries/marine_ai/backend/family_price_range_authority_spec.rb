# frozen_string_literal: true

require 'rails_helper'

# Phase 2A — the thin, read-only FamilyPriceRangeAuthority wrapper over PriceRangeRepository#range_for.
# The repository is an injected double so no catalog DB is touched; these examples pin the canonical
# immutable result, the adapter-owned source/checked_at stamp, and the fail-closed status mapping.
RSpec.describe Marine::Backend::FamilyPriceRangeAuthority do
  subject(:authority) { described_class.new(price_range_repository: repo, clock: -> { Time.utc(2026, 10, 2, 8, 30, 0) }) }

  let(:repo) { instance_double(Marine::Catalog::PriceRangeRepository) }

  it 'wraps an available range into the canonical immutable result with an adapter-stamped source/checked_at' do
    allow(repo).to receive(:range_for).with('FAM1').and_return(status: :available, min: '10', max: '20', currency: 'IDR', uom: 'Meter')

    result = authority.call(family_code: 'FAM1')

    expect(result.status).to eq(:available)
    expect(result).to be_available
    expect([result.min, result.max, result.currency, result.uom]).to eq(%w[10 20 IDR Meter])
    expect(result.source).to eq('catalog_price_range_repository')
    expect(result.checked_at).to eq('2026-10-02T08:30:00Z')
    expect(result).to be_frozen
    # B5 — recursive immutability: every carried String (including the adapter-stamped checked_at and
    # source) is frozen, so a frozen Struct with a mutable nested string can never slip through.
    expect([result.min, result.max, result.currency, result.uom, result.source, result.checked_at]).to all(be_frozen)
  end

  it 'maps :unavailable to range_unavailable with no facts' do
    allow(repo).to receive(:range_for).and_return(status: :unavailable)

    result = authority.call(family_code: 'FAM1')

    expect(result.status).to eq(:range_unavailable)
    expect(result).not_to be_available
    expect([result.min, result.max, result.source, result.checked_at]).to all(be_nil)
  end

  it 'maps :conflict to range_unavailable' do
    allow(repo).to receive(:range_for).and_return(status: :conflict)

    expect(authority.call(family_code: 'FAM1').status).to eq(:range_unavailable)
  end

  it 'maps a catalog outage to :outage' do
    allow(repo).to receive(:range_for).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)

    expect(authority.call(family_code: 'FAM1').status).to eq(:outage)
  end
end
