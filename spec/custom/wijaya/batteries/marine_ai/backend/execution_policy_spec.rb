# frozen_string_literal: true

require 'rails_helper'

# Phase 1 (Opsi B) + Phase 3 — the pure backend leaf that is the SINGLE source of truth for execution
# authorization AND the Model 1 classification vocabulary. These assertions prove the frozen closed
# vocabularies, the UNCHANGED EXACT-["price"] live-bridge authorization (#authorized?), the Phase-3
# single-intent product authorization (#product_authorized?) over price/product_listing/
# product_information, and — spec-only, never a production dependency — that the vocabularies are
# subsets of Marine::Decision::Schema::INTENTS.
RSpec.describe Marine::Backend::ExecutionPolicy do
  describe 'EXECUTABLE_INTENTS (the live price-bridge executable, UNCHANGED)' do
    it 'is exactly ["price"] and frozen' do
      expect(described_class::EXECUTABLE_INTENTS).to eq(%w[price])
      expect(described_class::EXECUTABLE_INTENTS).to be_frozen
    end
  end

  describe 'PRODUCT_INTENTS (the Phase-3/5 packet-path executable intents)' do
    it 'is exactly the five single-intent product reads and frozen' do
      expect(described_class::PRODUCT_INTENTS).to eq(%w[price price_range stock product_overview product_listing product_information])
      expect(described_class::PRODUCT_INTENTS).to be_frozen
    end
  end

  describe 'CLASSIFICATION_INTENTS' do
    it 'is the product intents plus the unsupported fallback, frozen' do
      expect(described_class::CLASSIFICATION_INTENTS)
        .to eq(%w[price price_range stock product_overview product_listing product_information unsupported])
      expect(described_class::CLASSIFICATION_INTENTS).to be_frozen
    end
  end

  describe 'immutable frozen projections' do
    it 'returns the frozen constant arrays' do
      expect(described_class.executable_intents).to equal(described_class::EXECUTABLE_INTENTS)
      expect(described_class.product_intents).to equal(described_class::PRODUCT_INTENTS)
      expect(described_class.classification_intents).to equal(described_class::CLASSIFICATION_INTENTS)
    end
  end

  describe '.authorized? (live price bridge — exact ["price"], UNCHANGED by Phase 3)' do
    it 'accepts EXACTLY the canonical ["price"] array' do
      expect(described_class.authorized?(%w[price])).to be(true)
      expect(described_class.authorized?(%w[price].dup)).to be(true)
    end

    it 'rejects the Phase-3 product intents and every duplicated/reordered/mixed/empty/non-array set' do
      expect(described_class.authorized?(%w[product_listing])).to be(false)
      expect(described_class.authorized?(%w[product_information])).to be(false)
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

  describe '.product_authorized? (Phase-3/5 packet path — single-intent sets only)' do
    it 'accepts EXACTLY each executable product intent as a one-element array' do
      expect(described_class.product_authorized?(%w[price])).to be(true)
      expect(described_class.product_authorized?(%w[price_range])).to be(true)
      expect(described_class.product_authorized?(%w[stock])).to be(true)
      expect(described_class.product_authorized?(%w[product_overview])).to be(true)
      expect(described_class.product_authorized?(%w[product_listing])).to be(true)
      expect(described_class.product_authorized?(%w[product_information])).to be(true)
      # A fresh (non-identical) array equal to a canonical single-intent set still passes.
      expect(described_class.product_authorized?(%w[price_range].dup)).to be(true)
    end

    it 'rejects a duplicated/reordered/mixed/empty/non-array or unactivated set (no dedupe, no sort)' do
      expect(described_class.product_authorized?(%w[price price])).to be(false)
      expect(described_class.product_authorized?(%w[price_range price_range])).to be(false)
      expect(described_class.product_authorized?(%w[stock stock])).to be(false)
      expect(described_class.product_authorized?(%w[price stock])).to be(false)
      expect(described_class.product_authorized?(%w[price price_range])).to be(false)
      expect(described_class.product_authorized?(%w[product_listing product_information])).to be(false)
      expect(described_class.product_authorized?(%w[catalog])).to be(false)
      expect(described_class.product_authorized?(%w[variant_info])).to be(false)
      expect(described_class.product_authorized?(%w[unsupported])).to be(false)
      expect(described_class.product_authorized?([])).to be(false)
      expect(described_class.product_authorized?('product_listing')).to be(false)
      expect(described_class.product_authorized?(nil)).to be(false)
    end
  end

  describe '.executable? / .product_executable?' do
    it 'executable? is true only for the live price intent (the live bridge is unchanged)' do
      expect(described_class.executable?('price')).to be(true)
      expect(described_class.executable?('price_range')).to be(false)
      expect(described_class.executable?('stock')).to be(false)
      expect(described_class.executable?('product_listing')).to be(false)
    end

    it 'product_executable? is true for each Phase-3/5 product intent only' do
      expect(described_class.product_executable?('price')).to be(true)
      expect(described_class.product_executable?('price_range')).to be(true)
      expect(described_class.product_executable?('stock')).to be(true)
      expect(described_class.product_executable?('product_overview')).to be(true)
      expect(described_class.product_executable?('product_listing')).to be(true)
      expect(described_class.product_executable?('product_information')).to be(true)
      expect(described_class.product_executable?('catalog')).to be(false)
      expect(described_class.product_executable?('unsupported')).to be(false)
    end
  end

  # SPEC-ONLY subset assertion: the production leaf has NO dependency on Schema; membership is proven
  # here so the policy can never drift outside the candidate vocabulary.
  describe 'membership inside the Schema vocabulary (spec-only, not a production dependency)' do
    it 'keeps every vocabulary a subset of Schema::INTENTS' do
      expect((described_class::EXECUTABLE_INTENTS - Marine::Decision::Schema::INTENTS)).to be_empty
      expect((described_class::PRODUCT_INTENTS - Marine::Decision::Schema::INTENTS)).to be_empty
      expect((described_class::CLASSIFICATION_INTENTS - Marine::Decision::Schema::INTENTS)).to be_empty
    end
  end
end
