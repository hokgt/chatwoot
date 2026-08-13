# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::ProductCatalogSelector, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }

  def catalog(family:, assistant: nil, status: :available)
    create(:marine_document, :product_catalog,
           assistant: assistant || self.assistant,
           product_family_code: family,
           status: status)
  end

  def select(family_code, target_account: account, target_assistant: assistant)
    described_class.new(account: target_account, assistant: target_assistant, family_code: family_code).call
  end

  it 'returns the single available primary catalog for the exact validated family' do
    document = catalog(family: 'IMP')

    expect(select('IMP')).to eq(document)
  end

  it 'returns nil when no catalog exists for that family' do
    catalog(family: 'IMP')

    expect(select('PUMP')).to be_nil
  end

  it 'returns nil for a blank family code without selecting anything' do
    catalog(family: 'IMP')

    expect(select('')).to be_nil
    expect(select('   ')).to be_nil
  end

  it 'returns nil when the single matching catalog has no attached source_file (unusable)' do
    document = catalog(family: 'IMP')
    document.source_file.detach

    expect(select('IMP')).to be_nil
  end

  it 'does not select an in_progress (not yet available) catalog' do
    catalog(family: 'IMP', status: :in_progress)

    expect(select('IMP')).to be_nil
  end

  it 'does not cross assistant scope' do
    other_assistant = create(:marine_assistant, account: account)
    catalog(family: 'IMP', assistant: other_assistant)

    expect(select('IMP')).to be_nil
  end

  it 'does not cross account scope' do
    document = catalog(family: 'IMP')
    other_account = create(:account)

    expect(select('IMP', target_account: other_account)).to be_nil
    expect(select('IMP')).to eq(document)
  end
end
