# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the closed-schema per-case acceptance artifact. Proves the contract is bounded, closed,
# fail-closed on malformed/unbounded/out-of-vocabulary input, and deeply immutable.
RSpec.describe Marine::ProductAuthority::AcceptanceCaseResult, type: :model do
  let(:valid_outcome) do
    { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['answer_price'] }
  end

  def valid_fields(overrides = {})
    {
      case_id: 'case_price_01', surface: 'evaluator',
      candidate_plan_status: 'valid', exact_quantity_status: 'clear', adapter_status: 'accepted',
      planner_status: 'planned', repository_revalidation_status: 'revalidated', evidence_packet_status: 'valid',
      expected_outcome: valid_outcome, actual_outcome: valid_outcome, reason: 'none', passed: true
    }.merge(overrides)
  end

  describe '.normalize_outcome' do
    it 'accepts a closed, bounded outcome and deep-freezes it' do
      normalized = described_class.normalize_outcome(valid_outcome)
      expect(normalized).to eq(valid_outcome)
      expect(normalized).to be_frozen
      expect(normalized[:intents]).to be_frozen
    end

    it 'rejects an unknown key, out-of-vocabulary code, duplicate, overflow, and non-hash' do
      expect(described_class.normalize_outcome(valid_outcome.merge(extra: 1))).to be_nil
      expect(described_class.normalize_outcome(valid_outcome.merge(status: 'invented'))).to be_nil
      expect(described_class.normalize_outcome(valid_outcome.merge(intents: ['teleport']))).to be_nil
      expect(described_class.normalize_outcome(valid_outcome.merge(response_goals: %w[answer_price answer_price]))).to be_nil
      overflow = %w[answer_price answer_stock answer_product_overview clarify_product handoff]
      expect(described_class.normalize_outcome(valid_outcome.merge(response_goals: overflow))).to be_nil
      expect(described_class.normalize_outcome('nope')).to be_nil
    end
  end

  describe '.build' do
    it 'produces a deeply immutable, closed-schema result' do
      result = described_class.build(**valid_fields)
      expect(result).to be_frozen
      expect(result.pass?).to be(true)
      expect(result.to_h).to be_frozen
      expect(result.to_h.keys).to contain_exactly(
        :schema_version, :case_id, :surface, :candidate_plan_status, :exact_quantity_status,
        :adapter_status, :planner_status, :repository_revalidation_status, :evidence_packet_status,
        :expected_outcome, :actual_outcome, :reason, :passed
      )
      expect { result.instance_variable_set(:@passed, false) }.to raise_error(FrozenError)
    end

    it 'fails closed on a bad enum, bad case id, bad surface, and non-boolean pass' do
      expect { described_class.build(**valid_fields(adapter_status: 'exploded')) }.to raise_error(described_class::InvalidCaseResult)
      expect { described_class.build(**valid_fields(case_id: 'has spaces!')) }.to raise_error(described_class::InvalidCaseResult)
      expect { described_class.build(**valid_fields(surface: 'email')) }.to raise_error(described_class::InvalidCaseResult)
      expect { described_class.build(**valid_fields(reason: 'because')) }.to raise_error(described_class::InvalidCaseResult)
      expect { described_class.build(**valid_fields(passed: 'yes')) }.to raise_error(described_class::InvalidCaseResult)
    end

    it 'fails closed on a malformed outcome and on missing/extra fields' do
      expect { described_class.build(**valid_fields(expected_outcome: { status: 'nope' })) }.to raise_error(described_class::InvalidCaseResult)
      expect { described_class.build(**valid_fields.except(:reason)) }.to raise_error(described_class::InvalidCaseResult)
      expect { described_class.build(**valid_fields(surprise: 1)) }.to raise_error(described_class::InvalidCaseResult)
    end
  end

  describe 'true deep immutability (sole ownership of caller-supplied strings)' do
    it 'is unaffected when the caller mutates its source strings after build' do
      mutable = valid_fields(
        case_id: +'case_mutable_01', surface: +'evaluator', reason: +'none',
        candidate_plan_status: +'valid', exact_quantity_status: +'clear', adapter_status: +'accepted',
        planner_status: +'planned', repository_revalidation_status: +'revalidated', evidence_packet_status: +'valid'
      )
      result = described_class.build(**mutable)
      snapshot = result.to_h

      mutable.each_value { |value| value << 'TAMPER' if value.is_a?(String) }

      expect(result.case_id).to eq('case_mutable_01')
      expect(result.reason).to eq('none')
      expect(result.adapter_status).to eq('accepted')
      expect(result.to_h).to eq(snapshot)
    end

    it 'freezes every scalar string field so a direct mutation raises FrozenError' do
      result = described_class.build(**valid_fields)
      %i[case_id surface candidate_plan_status exact_quantity_status adapter_status planner_status
         repository_revalidation_status evidence_packet_status reason].each do |field|
        expect(result.public_send(field)).to be_frozen
      end
      expect { result.case_id << 'x' }.to raise_error(FrozenError)
      expect { result.instance_variable_set(:@reason, 'tampered') }.to raise_error(FrozenError)
    end
  end

  describe 'deep-frozen outcome leaf strings (status + closed-list elements)' do
    it 'freezes the status duplicate and every list leaf so direct mutation raises FrozenError' do
      normalized = described_class.normalize_outcome(valid_outcome)
      expect(normalized[:status]).to be_frozen
      expect(normalized[:intents]).to all(be_frozen)
      expect(normalized[:slot_ops]).to all(be_frozen)
      expect(normalized[:response_goals]).to all(be_frozen)
      expect { normalized[:status] << 'TAMPER' }.to raise_error(FrozenError)
      expect { normalized[:intents].first << 'TAMPER' }.to raise_error(FrozenError)
      expect { normalized[:slot_ops].first << 'TAMPER' }.to raise_error(FrozenError)
      expect { normalized[:response_goals].first << 'TAMPER' }.to raise_error(FrozenError)
    end

    it 'leaves a built artifact unchanged when an expected/actual outcome leaf mutation is attempted' do
      result = described_class.build(**valid_fields)
      snapshot = result.to_h

      [result.expected_outcome, result.actual_outcome].each do |outcome|
        expect { outcome[:status] << 'TAMPER' }.to raise_error(FrozenError)
        expect { outcome[:intents].first << 'TAMPER' }.to raise_error(FrozenError)
        expect { outcome[:slot_ops].first << 'TAMPER' }.to raise_error(FrozenError)
        expect { outcome[:response_goals].first << 'TAMPER' }.to raise_error(FrozenError)
      end

      expect(result.expected_outcome).to eq(valid_outcome)
      expect(result.actual_outcome).to eq(valid_outcome)
      expect(result.to_h).to eq(snapshot)
    end
  end

  it 'draws its vocabulary from lower existing components (product-outcome, evidence builder, adapter)' do
    adapter = Marine::Backend::CandidatePlanToProductIntentAdapter
    expect(described_class::OUTCOME_STATUSES).to eq(Marine::ProductAuthority::ProductOutcome::STATUSES)
    expect(described_class::OUTCOME_INTENTS).to eq(Marine::ProductAuthority::ProductOutcome::INTENTS)
    expect(described_class::RESPONSE_GOALS).to eq(Marine::Backend::EvidencePacketBuilder::RESPONSE_GOALS)
    expect(described_class::MAX_RESPONSE_GOALS).to eq(Marine::Backend::EvidencePacketBuilder::MAX_RESPONSE_GOALS)
    expect(described_class::ADAPTER_BLOCK_REASONS).to contain_exactly(
      adapter::REASON_UNSUPPORTED_SCHEMA, adapter::REASON_UNRESOLVED_SCENARIO,
      adapter::REASON_SCENARIO_MISMATCH, adapter::REASON_UNSUPPORTED_INTENT,
      adapter::REASON_PHASE_NOT_EXECUTABLE
    )
    expect(described_class::REASONS).to include(*described_class::ADAPTER_BLOCK_REASONS)
  end

  it 'references no Evaluator constant in its production source (lower-level dependency for later extension)' do
    # Strip comments so only executable code is scanned (the isolation-spec convention).
    code = Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/acceptance_case_result.rb')
                .read.gsub(/#(?!\{).*/, '')
    expect(code).not_to include('Evaluator')
  end
end
