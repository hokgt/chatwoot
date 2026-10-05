# frozen_string_literal: true

require 'rails_helper'

# Phase 1 (Opsi B) — the pure backend leaf that is the SINGLE source of truth for execution
# authorization AND the Model 1 classification vocabulary. These assertions prove the frozen closed
# vocabularies, the EXACT-canonical-array authorization rule (no dedupe/sort), and — spec-only, never
# a production dependency — that both vocabularies are subsets of Marine::Decision::Schema::INTENTS.
RSpec.describe Marine::Backend::ExecutionPolicy do
  describe 'EXECUTABLE_INTENTS' do
    it 'is exactly ["price"] and frozen' do
      expect(described_class::EXECUTABLE_INTENTS).to eq(%w[price])
      expect(described_class::EXECUTABLE_INTENTS).to be_frozen
    end
  end

  describe 'CLASSIFICATION_INTENTS' do
    it 'is exactly ["price","unsupported"] and frozen' do
      expect(described_class::CLASSIFICATION_INTENTS).to eq(%w[price unsupported])
      expect(described_class::CLASSIFICATION_INTENTS).to be_frozen
    end
  end

  describe 'immutable frozen projections' do
    it 'returns the frozen constant arrays' do
      expect(described_class.executable_intents).to equal(described_class::EXECUTABLE_INTENTS)
      expect(described_class.classification_intents).to equal(described_class::CLASSIFICATION_INTENTS)
    end
  end

  describe '.authorized?' do
    it 'accepts EXACTLY the canonical ["price"] array' do
      expect(described_class.authorized?(%w[price])).to be(true)
      # A fresh (non-identical) array equal to the canonical set still passes.
      expect(described_class.authorized?(%w[price].dup)).to be(true)
    end

    it 'rejects a duplicated/reordered/mixed/empty/non-array set (no dedupe, no sort)' do
      expect(described_class.authorized?(%w[price price])).to be(false)
      expect(described_class.authorized?(%w[price stock])).to be(false)
      expect(described_class.authorized?(%w[stock price])).to be(false)
      expect(described_class.authorized?(%w[stock])).to be(false)
      expect(described_class.authorized?(%w[unsupported])).to be(false)
      expect(described_class.authorized?([])).to be(false)
      expect(described_class.authorized?('price')).to be(false)
      expect(described_class.authorized?(nil)).to be(false)
    end
  end

  describe '.executable?' do
    it 'is true only for a Phase-1 executable intent' do
      expect(described_class.executable?('price')).to be(true)
      expect(described_class.executable?('unsupported')).to be(false)
      expect(described_class.executable?('stock')).to be(false)
    end
  end

  # SPEC-ONLY subset assertion: the production leaf has NO dependency on Schema; membership is proven
  # here so the policy can never drift outside the candidate vocabulary.
  describe 'membership inside the Schema vocabulary (spec-only, not a production dependency)' do
    it 'keeps both vocabularies subsets of Schema::INTENTS' do
      expect((described_class::EXECUTABLE_INTENTS - Marine::Decision::Schema::INTENTS)).to be_empty
      expect((described_class::CLASSIFICATION_INTENTS - Marine::Decision::Schema::INTENTS)).to be_empty
    end
  end
end
