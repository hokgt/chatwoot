# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the BOUNDED, SANITIZED, synthetic labelled corpus for the product-authority evaluator.
# These examples pin the corpus contract the Evaluator relies on: a non-empty frozen table, every case
# carrying the exact required keys with a closed-vocabulary label status, unique ids, category coverage
# across the safety-critical surfaces, a Conversation/Playground parity pair, and CLEARLY SYNTHETIC
# candidate values (no PII / real product secret).
RSpec.describe Marine::ProductAuthority::Corpus do
  let(:cases) { described_class.cases }

  it 'is a non-empty frozen Array' do
    expect(cases).to be_an(Array)
    expect(cases).not_to be_empty
    expect(cases).to be_frozen
  end

  it 'gives every case the exact keys the Evaluator requires' do
    required = Marine::ProductAuthority::Evaluator::CASE_KEYS
    cases.each do |kase|
      expect(required - kase.keys).to be_empty, "case #{kase[:id].inspect} missing keys #{(required - kase.keys).inspect}"
    end
  end

  it 'gives every label the exact label key set' do
    label_keys = Marine::ProductAuthority::Evaluator::LABEL_KEYS
    cases.each do |kase|
      expect(label_keys - kase[:label].keys).to be_empty, "case #{kase[:id].inspect} label missing keys"
    end
  end

  it 'has unique case ids' do
    ids = cases.map { |kase| kase[:id] }
    expect(ids.uniq.length).to eq(ids.length)
  end

  it 'labels every case with a status in the closed ProductOutcome vocabulary' do
    cases.each do |kase|
      expect(Marine::ProductAuthority::ProductOutcome::STATUSES).to include(kase[:label][:status])
    end
  end

  it 'includes at least one critical safety case' do
    expect(cases.count { |kase| kase[:critical] }).to be >= 1
  end

  it 'covers every required category' do
    required_categories = %w[
      price stock price_stock overview catalog ambiguous_variant variant_correction
      stock_vs_order_status malformed unsupported_mixed capability_mismatch scenario_mismatch stock_failclosed
      exact_quantity parity
    ]
    present = cases.map { |kase| kase[:category] }.uniq
    required_categories.each { |category| expect(present).to include(category) }
  end

  it 'contains exactly one surface-aware parity case flagged for the dual-surface harness' do
    parity = cases.select { |kase| kase[:parity] }
    expect(parity.length).to eq(1)
    expect(parity.first).to include(surface: 'both', category: 'parity')
  end

  it 'includes a CRITICAL exact-quantity safety case carrying bounded safety metadata' do
    safety = cases.find { |kase| kase[:safety] }
    expect(safety).to include(critical: true, category: 'exact_quantity')
    expect(safety[:safety]).to eq(exact_quantity_request: true)
    expect(safety[:label]).to include(status: 'blocked', block_reason: 'exact_quantity_request')
  end

  it 'uses only CLEARLY SYNTHETIC exact family/variant candidate values (no PII / real secret)' do
    exact_types = %w[family_code variant_code]
    cases.each do |kase|
      Array(kase[:plan]['slot_operations']).each do |op|
        value = op['value']
        next unless value.is_a?(Hash) && exact_types.include?(value['candidate_type'])

        expect(value['raw_candidate']).to start_with('SYN'),
                                          "case #{kase[:id].inspect} exact candidate #{value['raw_candidate'].inspect} is not synthetic"
      end
    end
  end
end
