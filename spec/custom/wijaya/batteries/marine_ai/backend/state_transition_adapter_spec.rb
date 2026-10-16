# frozen_string_literal: true

require 'rails_helper'

# The pure StateTransitionAdapter: it maps an EXISTING, frozen Marine::Backend::ProductStateTransition
# Result's operation onto the closed proposed-state-transition operation enum and NOTHING else —
# :product_replacement -> :start, :variant_replacement -> :update, and every nil / wrong-class /
# wrong-schema / unknown-operation / mutable / malformed input fails closed to nil. It performs NO DB,
# repository, or provider work (it only reads the already-computed Result struct).
RSpec.describe Marine::Backend::StateTransitionAdapter do
  subject(:adapter) { described_class.new }

  # A real, frozen ProductStateTransition Result for the given kind (the pure helper itself, so the
  # contract the adapter consumes can never drift from the one it produces).
  def transition(kind:, family: 'FAM1')
    Marine::Backend::ProductStateTransition.new.call(existing: nil, kind: kind, set: { 'validated_family' => family })
  end

  it 'maps a product_replacement Result to :start' do
    expect(adapter.call(transition(kind: :product_replacement))).to eq(:start)
  end

  it 'maps a variant_replacement Result to :update' do
    expect(adapter.call(transition(kind: :variant_replacement))).to eq(:update)
  end

  it 'fails closed (nil) for a nil input' do
    expect(adapter.call(nil)).to be_nil
  end

  it 'fails closed (nil) for a wrong-class input' do
    expect(adapter.call({ operation: :product_replacement })).to be_nil
    expect(adapter.call(Object.new)).to be_nil
  end

  it 'fails closed (nil) for a Result carrying an unknown operation' do
    forged = Marine::Backend::ProductStateTransition::Result.new(
      schema_version: Marine::Backend::ProductStateTransition::SCHEMA_VERSION,
      operation: :terminate, invalidated_keys: [], changes: {}, snapshot: {}
    ).freeze
    expect(adapter.call(forged)).to be_nil
  end

  it 'fails closed (nil) for a Result carrying a mismatched schema_version' do
    forged = Marine::Backend::ProductStateTransition::Result.new(
      schema_version: 999, operation: :product_replacement, invalidated_keys: [], changes: {}, snapshot: {}
    ).freeze
    expect(adapter.call(forged)).to be_nil
  end

  it 'fails closed (nil) for a mutable (non-frozen) Result' do
    mutable = Marine::Backend::ProductStateTransition::Result.new(
      schema_version: Marine::Backend::ProductStateTransition::SCHEMA_VERSION,
      operation: :product_replacement, invalidated_keys: [], changes: {}, snapshot: {}
    )
    expect(mutable).not_to be_frozen
    expect(adapter.call(mutable)).to be_nil
  end

  it 'reads the Result only — it never touches a repository or the state store' do
    # Build the fixture FIRST (ProductStateTransition itself uses the store); the adapter call below
    # must touch neither the state store nor a repository.
    result = transition(kind: :product_replacement)
    expect(Marine::Catalog::ProductFlowStateStore).not_to receive(:new)
    expect(Marine::Catalog::ProductFamilyRepository).not_to receive(:new)

    expect(adapter.call(result)).to eq(:start)
  end
end
