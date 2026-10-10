# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Backend::ListingScopeResolver do
  subject(:resolver) { described_class.new(repository: repository) }

  let(:repository) { instance_double(Marine::Catalog::ProductListingRepository) }
  let(:missing) { { status: :missing } }

  before do
    allow(repository).to receive(:resolve_top_level_any).and_return(missing)
    allow(repository).to receive(:resolve_item_group_any).and_return(missing)
    allow(repository).to receive(:infer_item_group_from_top_level_any).and_return(missing)
  end

  it 'resolves an exact authoritative Item Group token from the current trigger' do
    expect(repository).to receive(:resolve_item_group_any) do |candidates|
      expect(candidates).to include('Kain')
      { status: :resolved, item_group: 'Kain' }
    end

    result = resolver.call(trigger: 'Kain yang tersedia apa saja?')
    expect(result.status).to eq(:item_group)
    expect(result.item_group).to eq('Kain')
    expect(result.product).to be_nil
  end

  it 'resolves product and Item Group namespaces independently' do
    allow(repository).to receive(:resolve_top_level_any).and_return(status: :resolved, code: 'KAIN', name: 'Kain')
    allow(repository).to receive(:resolve_item_group_any).and_return(status: :resolved, item_group: 'Kain')

    result = resolver.call(trigger: 'Kain yang tersedia apa saja?')
    expect(result.status).to eq(:ambiguous)
    expect(result.product).to be_nil
    expect(result.item_group).to be_nil
  end

  it 'fails closed when an exact product also implies an inferred Item Group' do
    allow(repository).to receive(:resolve_top_level_any)
      .and_return(status: :resolved, code: 'KAIN', name: 'Kain')
    allow(repository).to receive(:infer_item_group_from_top_level_any)
      .and_return(status: :resolved, item_group: 'Fabric')

    result = resolver.call(trigger: 'Kain yang tersedia apa saja?')
    expect(result.status).to eq(:ambiguous)
    expect(result.product).to be_nil
    expect(result.item_group).to be_nil
  end

  it 'fails closed on ambiguity or an unavailable namespace' do
    allow(repository).to receive(:resolve_top_level_any).and_return(status: :ambiguous)
    expect(resolver.call(trigger: 'Alpha tersedia?').status).to eq(:ambiguous)

    allow(repository).to receive(:resolve_top_level_any).and_return(status: :missing)
    allow(repository).to receive(:resolve_item_group_any).and_return(status: :unavailable)
    expect(resolver.call(trigger: 'Alpha tersedia?').status).to eq(:unavailable)
  end

  it 'infers a category from a generic token only through unanimous top-level product evidence' do
    expect(repository).to receive(:infer_item_group_from_top_level_any) do |candidates|
      expect(candidates.map(&:downcase)).to include('kain')
      { status: :resolved, item_group: 'Fabric' }
    end

    result = resolver.call(trigger: 'kain')
    expect(result.status).to eq(:item_group)
    expect(result.item_group).to eq('Fabric')
  end

  it 'fails closed for a nonblank trigger with no exact or inferred authority' do
    expect(resolver.call(trigger: 'unknown-category').status).to eq(:ambiguous)
  end

  it 'returns broad only for a genuinely blank trigger' do
    expect(repository).not_to receive(:resolve_top_level_any)
    expect(resolver.call(trigger: '   ').status).to eq(:broad)
  end

  it 'fails closed when inferred product matches span multiple groups or overflow' do
    allow(repository).to receive(:infer_item_group_from_top_level_any).and_return(status: :ambiguous)
    expect(resolver.call(trigger: 'kain').status).to eq(:ambiguous)
  end

  it 'fails closed rather than truncate an overflowing candidate set' do
    trigger = (1..40).map { |index| "token#{index}" }.join(' ')
    expect(repository).not_to receive(:resolve_top_level_any)
    expect(repository).not_to receive(:resolve_item_group_any)
    expect(resolver.call(trigger: trigger).status).to eq(:ambiguous)
  end
end
