# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2c — the ACCEPTANCE-ONLY adapter over the REAL runtime intent seam
# (Marine::Catalog::IntentExtractor#extract). This spec pins the full chain the readiness work needs:
# a corpus case -> the EXISTING parity synthetic customer turn -> the real #extract -> a canonical
# quantity_inquiry boolean -> the acceptance decision. It proves the seam returns a canonical signal
# ONLY for a NORMALIZED extraction (reason 'extracted'/'not_product' with a boolean), returns nil
# (fail-closed, fall back to corpus safety) for a degraded/malformed/raising extraction, and that the
# AcceptanceRunner + Parity::Runtime now consume that real seam by DEFAULT — so the corpus safety
# fallback is no longer the only source of the exact-quantity decision. No provider/network is touched;
# the real IntentExtractor is stubbed with a verifying instance_double.
RSpec.describe Marine::ProductAuthority::IntentExtractorSeam do
  extractor_class = Marine::Catalog::IntentExtractor
  conversation_intake = Marine::ProductAuthority::Parity::IntakeAdapters::ConversationIntake

  def corpus_case(id)
    Marshal.load(Marshal.dump(Marine::ProductAuthority::Corpus.cases.find { |kase| kase[:id] == id }))
  end

  # A full IntentExtractor contract hash with overridable reason / quantity_inquiry (every other field
  # is the extractor's safe default; the seam only reads :reason and :quantity_inquiry).
  def extraction(reason: 'extracted', quantity_inquiry: false)
    {
      product_related: true, intent: 'stock', requested_intents: ['stock'], family_mention: nil,
      explicit_child_code: nil, attribute_candidates: [], requires_exact_variant: false,
      clarification_reply: nil, family_changed: false, intent_changed: false, intent_scope: nil,
      multiple_numeric_candidates: false, quantity_inquiry: quantity_inquiry, unsupported_request: nil,
      confidence: 'low', customer_language: nil, reason: reason
    }
  end

  describe '#call over the real seam contract' do
    let(:kase) { corpus_case('stock_available') }
    let(:stub) { instance_double(extractor_class) }

    it 'projects the EXISTING synthetic parity message into the real #extract (text/context/state)' do
      expected_text = conversation_intake.synthetic_message(kase)
      expect(stub).to receive(:extract).with(text: expected_text, context: nil, state: nil)
                                       .and_return(extraction(reason: 'extracted', quantity_inquiry: true))

      described_class.new(intent_extractor: stub).call(kase)
    end

    it 'returns the frozen canonical signal for a NORMALIZED extraction with quantity_inquiry true' do
      allow(stub).to receive(:extract).and_return(extraction(reason: 'extracted', quantity_inquiry: true))
      signal = described_class.new(intent_extractor: stub).call(kase)

      expect(signal).to eq(source: 'intent_extractor_seam', quantity_inquiry: true, reason_code: 'extracted')
      expect(signal).to be_frozen
    end

    it 'carries the quantity_inquiry false variant through unchanged' do
      allow(stub).to receive(:extract).and_return(extraction(reason: 'not_product', quantity_inquiry: false))
      expect(described_class.new(intent_extractor: stub).call(kase))
        .to eq(source: 'intent_extractor_seam', quantity_inquiry: false, reason_code: 'not_product')
    end

    it 'treats a DEGRADED unknown_result (llm_unavailable) as NO canonical signal (nil)' do
      extractor_class::REASONS.grep(/^llm_|malformed/).each do |degraded|
        allow(stub).to receive(:extract).and_return(extraction(reason: degraded, quantity_inquiry: false))
        expect(described_class.new(intent_extractor: stub).call(kase)).to be_nil
      end
    end

    it 'returns nil for a malformed result (non-Hash, or non-boolean quantity_inquiry)' do
      allow(stub).to receive(:extract).and_return('not-a-hash')
      expect(described_class.new(intent_extractor: stub).call(kase)).to be_nil

      allow(stub).to receive(:extract).and_return(extraction(reason: 'extracted', quantity_inquiry: 'yes'))
      expect(described_class.new(intent_extractor: stub).call(kase)).to be_nil
    end

    it 'fails closed to nil when the extractor raises (no exception leaks)' do
      allow(stub).to receive(:extract).and_raise(RuntimeError, 'SECRET-EXTRACT-TRACE')
      expect { expect(described_class.new(intent_extractor: stub).call(kase)).to be_nil }.not_to raise_error
    end
  end

  # END-TO-END acceptance consumption via the DEFAULT seam: the stubbed real extractor is injected INTO
  # the seam, and the seam is passed as the acceptance surfaces' extractor, proving the canonical signal
  # flows message -> #extract -> canonical boolean -> acceptance decision.
  describe 'AcceptanceRunner consumes the canonical signal via the real seam' do
    runner = Marine::ProductAuthority::AcceptanceRunner

    def seam_with(reason:, quantity_inquiry:)
      stub = instance_double(Marine::Catalog::IntentExtractor,
                             extract: extraction(reason: reason, quantity_inquiry: quantity_inquiry))
      described_class.new(intent_extractor: stub)
    end

    it 'blocks the exact-quantity case when the real seam yields quantity_inquiry true (extracted)' do
      report = runner.run([corpus_case('exact_quantity_failclosed')],
                          extractor: seam_with(reason: 'extracted', quantity_inquiry: true))
      evidence = report[:case_evidence].first

      expect(evidence.exact_quantity_status).to eq('blocked')
      expect(evidence.reason).to eq('exact_quantity_request')
    end

    it 'lets a canonical false from the real seam override the safety fallback (existing canonical-wins precedence)' do
      report = runner.run([corpus_case('exact_quantity_failclosed')],
                          extractor: seam_with(reason: 'extracted', quantity_inquiry: false))
      expect(report[:case_evidence].first.exact_quantity_status).to eq('clear')
    end

    it 'falls back to the corpus safety metadata when the seam is DEGRADED (nil signal)' do
      report = runner.run([corpus_case('exact_quantity_failclosed')],
                          extractor: seam_with(reason: 'llm_unavailable', quantity_inquiry: false))
      evidence = report[:case_evidence].first

      expect(evidence.exact_quantity_status).to eq('blocked')
      expect(evidence.reason).to eq('exact_quantity_request')
    end
  end

  describe 'Parity::Runtime consumes the canonical signal identically on both surfaces' do
    parity = Marine::ProductAuthority::Parity::Runtime

    it 'blocks BOTH surface folds when the real seam yields quantity_inquiry true' do
      stub = instance_double(Marine::Catalog::IntentExtractor,
                             extract: extraction(reason: 'extracted', quantity_inquiry: true))
      report = parity.run([corpus_case('exact_quantity_failclosed')],
                          extractor: described_class.new(intent_extractor: stub))
      entry = report[:case_evidence].first

      expect(entry[:conversation].exact_quantity_status).to eq('blocked')
      expect(entry[:playground].exact_quantity_status).to eq('blocked')
      expect(entry[:parity_ok]).to be(true)
    end
  end
end
