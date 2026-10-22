# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 1 — the battery-local, side-effect-free, versioned Candidate Plan
# contract for the future Decision Maker. These examples drive the PUBLIC facade
# (Marine::Decision::CandidatePlan), which normalizes fully UNTRUSTED provider output
# into a strict, bounded, deep-frozen candidate plan or raises
# Marine::Decision::Errors::InvalidCandidatePlan on any contract violation. Nothing here
# touches a provider, settings, the runner, the catalog, or any state — it is structure
# and normalization only. All product/variant strings are SYNTHETIC candidates.
RSpec.describe Marine::Decision::CandidatePlan do
  let(:invalid_error) { Marine::Decision::Errors::InvalidCandidatePlan }

  # A minimal, fully valid raw provider hash (string keys, as parsed JSON would be).
  def valid_raw(overrides = {})
    {
      'schema_version' => 'marine_decision_v1',
      'scenario_candidate' => { 'key' => 'stock_check', 'confidence' => 'high' },
      'intents' => ['stock'],
      'slot_operations' => [op('set', 'product', val('Santorini', 'display_name'))],
      'customer_language' => 'id',
      'confidence' => 'medium'
    }.merge(overrides)
  end

  # Small builders so the many slot-operation literals stay readable and within bounds.
  def val(raw, type)
    { 'raw_candidate' => raw, 'candidate_type' => type }
  end

  def op(operation, slot, value = :absent)
    h = { 'operation' => operation, 'slot' => slot }
    h['value'] = value unless value == :absent
    h
  end

  # A valid_raw whose slot_operations are exactly the given ops.
  def with_ops(*ops)
    valid_raw('slot_operations' => ops)
  end

  describe '.normalize' do
    it 'normalizes a valid product + variant_input plan into the canonical shape' do
      plan = described_class.normalize(
        with_ops(
          op('set', 'product', val('Santorini', 'family_code')),
          op('replace', 'variant_input', val('12mm', 'attribute_value'))
        )
      )

      expect(plan[:schema_version]).to eq('marine_decision_v1')
      expect(plan[:scenario_candidate]).to eq(key: 'stock_check', confidence: 'high')
      expect(plan[:intents]).to eq(['stock'])
      expect(plan[:customer_language]).to eq('id')
      expect(plan[:confidence]).to eq('medium')
      expect(plan[:reason]).to eq('normalized')
      expect(plan[:slot_operations]).to eq(
        [
          { operation: 'set', slot: 'product', value: { raw_candidate: 'Santorini', candidate_type: 'family_code' } },
          { operation: 'replace', slot: 'variant_input', value: { raw_candidate: '12mm', candidate_type: 'attribute_value' } }
        ]
      )
    end

    it 'dedupes and canonically orders a multi-intent set independent of provider ordering' do
      plan = described_class.normalize(valid_raw('intents' => %w[stock price stock catalog price]))

      # Canonical order follows Schema::INTENTS (price before stock before catalog).
      expect(plan[:intents]).to eq(%w[price stock catalog])
    end

    it 'accepts order_status and sample as candidate-only, non-authoritative intents' do
      plan = described_class.normalize(valid_raw('intents' => %w[order_status sample], 'slot_operations' => []))

      # They survive as bounded suggestions; the plan carries no action/fulfilment authority.
      expect(plan[:intents]).to eq(%w[order_status sample])
      expect(plan[:slot_operations]).to eq([])
      expect(plan).not_to have_key(:action)
    end

    it 'normalizes set, replace, and clear operations and orders them by slot' do
      plan = described_class.normalize(
        with_ops(op('clear', 'variant_input'), op('set', 'product', val('Mykonos', 'display_name')))
      )

      expect(plan[:slot_operations]).to eq(
        [
          { operation: 'set', slot: 'product', value: { raw_candidate: 'Mykonos', candidate_type: 'display_name' } },
          { operation: 'clear', slot: 'variant_input', value: nil }
        ]
      )
    end

    it 'tolerates symbol keys and falls back to safe defaults for absent optionals' do
      plan = described_class.normalize(schema_version: 'marine_decision_v1')

      expect(plan[:scenario_candidate]).to eq(key: nil, confidence: 'low')
      expect(plan[:intents]).to eq([])
      expect(plan[:slot_operations]).to eq([])
      expect(plan[:customer_language]).to be_nil
      expect(plan[:confidence]).to eq('low')
      expect(plan[:reason]).to eq('normalized')
    end

    it 'returns a deep-frozen, unmutatable plan' do
      plan = described_class.normalize(valid_raw)

      expect(plan).to be_frozen
      expect(plan[:intents]).to be_frozen
      expect(plan[:scenario_candidate]).to be_frozen
      expect(plan[:slot_operations].first).to be_frozen
      expect(plan[:slot_operations].first[:value]).to be_frozen
      expect { plan[:intents] << 'price' }.to raise_error(FrozenError)
      expect { plan[:reason] << 'x' }.to raise_error(FrozenError)
    end

    it 'does not mutate the input hash' do
      raw = valid_raw
      snapshot = Marshal.load(Marshal.dump(raw))

      described_class.normalize(raw)

      expect(raw).to eq(snapshot)
    end

    context 'when the structure or values violate the contract' do
      it 'rejects a non-hash input' do
        expect { described_class.normalize('nope') }.to raise_error(invalid_error)
        expect { described_class.normalize(nil) }.to raise_error(invalid_error)
      end

      it 'rejects an unknown or missing schema version' do
        expect { described_class.normalize(valid_raw('schema_version' => 'marine_decision_v2')) }.to raise_error(invalid_error)
        expect { described_class.normalize(valid_raw.except('schema_version')) }.to raise_error(invalid_error)
      end

      it 'rejects unknown top-level and nested keys' do
        expect { described_class.normalize(valid_raw('surprise' => 1)) }.to raise_error(invalid_error)
        bad_scenario = { 'key' => 'x', 'confidence' => 'low', 'extra' => 1 }
        expect { described_class.normalize(valid_raw('scenario_candidate' => bad_scenario)) }.to raise_error(invalid_error)
      end

      it 'rejects prohibited authority fields (validated facts, action, reply)' do
        %w[validated_variant_code validated_family price stock quantity warehouse action reply tool sql].each do |field|
          expect { described_class.normalize(valid_raw(field => 'x')) }.to raise_error(invalid_error)
        end
      end

      it 'rejects malformed top-level and nested types' do
        expect { described_class.normalize(valid_raw('scenario_candidate' => 'string')) }.to raise_error(invalid_error)
        expect { described_class.normalize(valid_raw('intents' => 'stock')) }.to raise_error(invalid_error)
        expect { described_class.normalize(valid_raw('slot_operations' => { 'operation' => 'set' })) }.to raise_error(invalid_error)
        expect { described_class.normalize(valid_raw('slot_operations' => ['string'])) }.to raise_error(invalid_error)
      end

      it 'rejects unknown enum values (confidence, intent, operation, slot, candidate type)' do
        expect { described_class.normalize(valid_raw('confidence' => 'certain')) }.to raise_error(invalid_error)
        expect { described_class.normalize(valid_raw('intents' => ['refund'])) }.to raise_error(invalid_error)
        expect { described_class.normalize(with_ops(op('append', 'product', val('x', 'display_name')))) }.to raise_error(invalid_error)
        expect { described_class.normalize(with_ops(op('set', 'color', val('x', 'display_name')))) }.to raise_error(invalid_error)
        expect { described_class.normalize(with_ops(op('set', 'product', val('x', 'variant_code')))) }.to raise_error(invalid_error)
      end

      it 'rejects duplicate slot operations on the same slot' do
        dup = with_ops(op('set', 'product', val('a', 'display_name')), op('clear', 'product'))
        expect { described_class.normalize(dup) }.to raise_error(invalid_error)
      end

      it 'rejects incompatible clear/value and set/replace without a value object' do
        expect { described_class.normalize(with_ops(op('clear', 'product', val('a', 'display_name')))) }.to raise_error(invalid_error)
        expect { described_class.normalize(with_ops(op('set', 'product'))) }.to raise_error(invalid_error)
        expect { described_class.normalize(with_ops(op('replace', 'product', nil))) }.to raise_error(invalid_error)
      end

      it 'rejects control characters and over-length / over-cardinality values' do
        expect { described_class.normalize(with_ops(op('set', 'product', val("bad\acode", 'display_name')))) }.to raise_error(invalid_error)
        expect { described_class.normalize(with_ops(op('set', 'product', val('a' * 121, 'display_name')))) }.to raise_error(invalid_error)
        long_key = { 'key' => 'k' * 121, 'confidence' => 'low' }
        expect { described_class.normalize(valid_raw('scenario_candidate' => long_key)) }.to raise_error(invalid_error)
        too_many = %w[price stock parent_info variant_info catalog product_overview order_status]
        expect { described_class.normalize(valid_raw('intents' => too_many)) }.to raise_error(invalid_error)
        expect { described_class.normalize(valid_raw('customer_language' => 'not-a-real-language-code')) }.to raise_error(invalid_error)
      end

      it 'rejects prohibited/unknown authority fields nested in scenario and value objects' do
        bad_scenario = { 'key' => 'stock_check', 'confidence' => 'low', 'price' => 9 }
        expect { described_class.normalize(valid_raw('scenario_candidate' => bad_scenario)) }.to raise_error(invalid_error)
        bad_value = { 'raw_candidate' => 'x', 'candidate_type' => 'display_name', 'validated_variant_code' => 'BD-1' }
        expect { described_class.normalize(with_ops(op('set', 'product', bad_value))) }.to raise_error(invalid_error)
      end

      it 'rejects a hash carrying both the String and Symbol form of the same key (top level and nested)' do
        clash_top = valid_raw
        clash_top[:confidence] = 'high'
        expect { described_class.normalize(clash_top) }.to raise_error(invalid_error)

        clash_scenario = { 'key' => 'stock_check', :key => 'other', 'confidence' => 'low' }
        expect { described_class.normalize(valid_raw('scenario_candidate' => clash_scenario)) }.to raise_error(invalid_error)

        clash_value = { 'raw_candidate' => 'x', :raw_candidate => 'y', 'candidate_type' => 'display_name' }
        expect { described_class.normalize(with_ops(op('set', 'product', clash_value))) }.to raise_error(invalid_error)
      end

      it 'rejects a blank enum but treats a blank optional language or scenario key as nil' do
        expect { described_class.normalize(valid_raw('confidence' => '')) }.to raise_error(invalid_error)
        expect(described_class.normalize(valid_raw('customer_language' => '   '))[:customer_language]).to be_nil
        blank_key = { 'key' => '   ', 'confidence' => 'low' }
        expect(described_class.normalize(valid_raw('scenario_candidate' => blank_key))[:scenario_candidate]).to eq(key: nil, confidence: 'low')
      end

      it 'rejects control characters in the scenario key and customer language' do
        bad_key = { 'key' => "stock\tcheck", 'confidence' => 'low' }
        expect { described_class.normalize(valid_raw('scenario_candidate' => bad_key)) }.to raise_error(invalid_error)
        expect { described_class.normalize(valid_raw('customer_language' => "i\x00d")) }.to raise_error(invalid_error)
      end

      it 'enforces the raw-array anti-DoS bound at exactly 32/33 (isolated via duplicate intents)' do
        # 32 raw entries clear the bound; distinct-count dedupe then folds them to one intent.
        expect(described_class.normalize(valid_raw('intents' => Array.new(32, 'price'), 'slot_operations' => []))[:intents]).to eq(['price'])
        expect { described_class.normalize(valid_raw('intents' => Array.new(33, 'price'), 'slot_operations' => [])) }.to raise_error(invalid_error)
      end

      it 'accepts a 120-char candidate and rejects 121' do
        ok = described_class.normalize(with_ops(op('set', 'product', val('a' * 120, 'display_name'))))
        expect(ok[:slot_operations].first[:value][:raw_candidate].length).to eq(120)
        expect { described_class.normalize(with_ops(op('set', 'product', val('a' * 121, 'display_name')))) }.to raise_error(invalid_error)
      end

      it 'accepts a valid Unicode product candidate with its case preserved' do
        plan = described_class.normalize(with_ops(op('set', 'product', val('Café Ñoño 日本', 'display_name'))))
        expect(plan[:slot_operations].first[:value][:raw_candidate]).to eq('Café Ñoño 日本')
      end
    end

    context 'with the canonical scenario key contract' do
      def with_key(key)
        valid_raw('scenario_candidate' => { 'key' => key, 'confidence' => 'low' })
      end

      it 'accepts a canonical lowercase snake_case key' do
        expect(described_class.normalize(with_key('stock_check_2'))[:scenario_candidate][:key]).to eq('stock_check_2')
      end

      it 'accepts a single-letter key and a 120-char key, and rejects 121' do
        expect(described_class.normalize(with_key('a'))[:scenario_candidate][:key]).to eq('a')
        max_key = "a#{'z' * 119}"
        expect(described_class.normalize(with_key(max_key))[:scenario_candidate][:key]).to eq(max_key)
        expect { described_class.normalize(with_key("a#{'z' * 120}")) }.to raise_error(invalid_error)
      end

      it 'rejects uppercase, hyphen, whitespace/punctuation, and leading-digit forms fail-closed' do
        ['Stock_Check', 'stock-check', 'stock check', 'stock!', '1stock'].each do |bad|
          expect { described_class.normalize(with_key(bad)) }.to raise_error(invalid_error)
        end
      end

      it 'treats an absent or blank key as nil without transforming' do
        expect(described_class.normalize(with_key(nil))[:scenario_candidate][:key]).to be_nil
        expect(described_class.normalize(with_key('   '))[:scenario_candidate][:key]).to be_nil
      end
    end

    context 'with the minimum-authority intent bound' do
      it 'accepts exactly 4 distinct intents and rejects 5' do
        four = %w[price stock parent_info variant_info]
        expect(described_class.normalize(valid_raw('intents' => four, 'slot_operations' => []))[:intents]).to eq(four)
        five = %w[price stock parent_info variant_info catalog]
        expect { described_class.normalize(valid_raw('intents' => five, 'slot_operations' => [])) }.to raise_error(invalid_error)
      end
    end

    context 'with deep-freeze that never touches external objects' do
      it 'returns fresh owned intent strings and never freezes the shared Schema::INTENTS constants' do
        frozen_before = Marine::Decision::Schema::INTENTS.map(&:frozen?)
        plan = described_class.normalize(valid_raw('intents' => %w[stock price], 'slot_operations' => []))

        expect(plan[:intents]).to all(be_frozen)
        const_ids = Marine::Decision::Schema::INTENTS.map(&:object_id)
        expect(plan[:intents].map(&:object_id) & const_ids).to be_empty
        expect(Marine::Decision::Schema::INTENTS.map(&:frozen?)).to eq(frozen_before)
      end
    end

    it 'ignores any provider-supplied top-level reason and stays normalizer-owned' do
      plan = described_class.normalize(valid_raw('reason' => 'provider prose to ignore'))

      expect(plan[:reason]).to eq('normalized')
    end
  end

  describe '.unknown' do
    it 'builds a safe, deep-frozen fallback plan carrying only an allowlisted reason' do
      plan = described_class.unknown('timeout')

      expect(plan).to be_frozen
      expect(plan[:schema_version]).to eq('marine_decision_v1')
      expect(plan[:scenario_candidate]).to eq(key: nil, confidence: 'low')
      expect(plan[:intents]).to eq([])
      expect(plan[:slot_operations]).to eq([])
      expect(plan[:customer_language]).to be_nil
      expect(plan[:confidence]).to eq('low')
      expect(plan[:reason]).to eq('timeout')
    end

    it 'exposes every documented failure reason and defaults unknown reasons safely' do
      %w[malformed_response unsupported_schema timeout provider_error unconfigured].each do |reason|
        expect(described_class.unknown(reason)[:reason]).to eq(reason)
      end
      expect(described_class.unknown('KABOOM: raw provider text here')[:reason]).to eq('malformed_response')
      expect(described_class.unknown[:reason]).to eq('malformed_response')
    end

    it 'never embeds raw error or provider prose in the plan' do
      plan = described_class.unknown('PG::ConnectionBad: could not connect at 10.0.0.1')

      expect(plan.values.map(&:to_s).join(' ')).not_to include('PG::ConnectionBad')
      expect(Marine::Decision::Schema::UNKNOWN_REASONS).to include(plan[:reason])
    end

    it 'never freezes a caller-supplied reason string' do
      reason = +'timeout' # explicitly mutable caller-owned string
      plan = described_class.unknown(reason)

      expect(plan[:reason]).to eq('timeout')
      expect(plan[:reason]).to be_frozen
      expect(plan[:reason]).not_to equal(reason)
      expect(reason).not_to be_frozen
    end
  end
end
