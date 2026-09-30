# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-1 (isolated / mock-only) — pure proposed product-flow state invalidation. It uses the
# REAL ProductFlowStateStore field names and its in-memory snapshot twin, and NEVER persists.
RSpec.describe Marine::Backend::ProductStateTransition do
  subject(:transition) { described_class.new }

  let(:existing) do
    {
      'version' => 3, 'flow_id' => 'flow-1', 'status' => 'active',
      'expires_at' => (Time.current + 3600).iso8601,
      'original_intent' => 'price', 'current_intent' => 'price',
      'requested_intents' => %w[price stock],
      'validated_family' => 'BD', 'validated_variant' => 'BD-4',
      'expected_attributes' => %w[Colour],
      'clarification_kind' => 'variant', 'clarification_count' => 1, 'clarification_family_codes' => %w[BD],
      'catalog_sent' => true, 'catalog_document_id' => 10, 'catalog_message_id' => 20
    }
  end

  describe 'product replacement' do
    subject(:result) { transition.call(existing: existing, kind: :product_replacement, set: { validated_family: 'PL' }) }

    it 'clears variant + catalog + clarification state, sets the new family, preserves the still-valid intents' do
      snapshot = result.snapshot
      expect(snapshot['validated_family']).to eq('PL')
      expect(snapshot).not_to have_key('validated_variant')
      expect(snapshot['expected_attributes']).to eq([])
      expect(snapshot).not_to have_key('clarification_kind')
      expect(snapshot).not_to have_key('clarification_count')
      expect(snapshot).not_to have_key('clarification_family_codes')
      expect(snapshot['catalog_sent']).to be(false)
      expect(snapshot).not_to have_key('catalog_document_id')
      expect(snapshot).not_to have_key('catalog_message_id')
      # Still-valid intents preserved (not cleared).
      expect(snapshot['current_intent']).to eq('price')
      expect(snapshot['requested_intents']).to eq(%w[price stock])
    end

    it 'uses the real ProductFlowStateStore field names for invalidation' do
      expect(result.invalidated_keys).to eq(described_class::PRODUCT_REPLACEMENT_KEYS)
      expect(described_class::PRODUCT_REPLACEMENT_KEYS - Marine::Catalog::ProductFlowStateStore::FIELDS).to be_empty
    end

    it 'carries a schema_version SEPARATE from the store revision version' do
      expect(result.schema_version).to eq(1)
      expect(result.snapshot['version']).to eq(4)
      expect(result.schema_version).not_to eq(result.snapshot['version'])
    end

    it 'is deeply frozen and never persists (conversation-free store)' do
      expect(result.snapshot).to be_frozen
      expect(result.changes).to be_frozen
    end
  end

  describe 'variant replacement' do
    subject(:result) { transition.call(existing: existing, kind: :variant_replacement) }

    it 'clears only variant-dependent clarification/facts, preserving the catalog metadata' do
      snapshot = result.snapshot
      expect(snapshot).not_to have_key('validated_variant')
      expect(snapshot['expected_attributes']).to eq([])
      expect(snapshot).not_to have_key('clarification_kind')
      expect(snapshot['validated_family']).to eq('BD')
      expect(snapshot['catalog_sent']).to be(true)
      expect(snapshot['catalog_document_id']).to eq(10)
    end

    it 'uses only the variant-dependent real keys' do
      expect(result.invalidated_keys).to eq(described_class::VARIANT_DEPENDENT_KEYS)
      expect(described_class::VARIANT_DEPENDENT_KEYS - Marine::Catalog::ProductFlowStateStore::FIELDS).to be_empty
    end
  end

  it 'seeds a fresh flow when there is no prior state' do
    result = transition.call(existing: nil, kind: :product_replacement, set: { validated_family: 'PL', current_intent: 'price' })
    expect(result.snapshot['version']).to eq(1)
    expect(result.snapshot['validated_family']).to eq('PL')
    expect(result.snapshot['current_intent']).to eq('price')
  end

  describe 'fail-closed API' do
    it 'rejects an unknown transition kind' do
      expect { transition.call(existing: existing, kind: :nonsense) }.to raise_error(ArgumentError)
    end

    it 'fails closed on a product replacement without a nonblank validated_family replacement' do
      expect { transition.call(existing: existing, kind: :product_replacement) }.to raise_error(ArgumentError)
      expect { transition.call(existing: existing, kind: :product_replacement, set: { validated_family: '  ' }) }.to raise_error(ArgumentError)
    end

    it 'rejects an unknown set key and a non-Hash set' do
      expect { transition.call(existing: existing, kind: :variant_replacement, set: { bogus: 1 }) }.to raise_error(ArgumentError)
      expect { transition.call(existing: existing, kind: :variant_replacement, set: 'nope') }.to raise_error(ArgumentError)
    end

    it 'never sets price or stock in the snapshot or the changes' do
      result = transition.call(existing: existing, kind: :product_replacement, set: { validated_family: 'PL' })
      expect(result.snapshot).not_to have_key('price')
      expect(result.snapshot).not_to have_key('stock')
      expect(result.changes.keys).not_to include('price', 'stock')
    end
  end
end
