# frozen_string_literal: true

# Fase 3A-2c — ACCEPTANCE-ONLY thin adapter over the REAL runtime intent seam. It bridges the
# plan-based acceptance surfaces (AcceptanceRunner, Parity::Runtime) to the SAME canonical runtime
# seam the live product path uses — Marine::Catalog::IntentExtractor#extract — so an acceptance run's
# `quantity_inquiry` is sourced from the real extraction contract rather than only from the corpus
# safety-harness metadata.
#
# A corpus case carries no extractable customer text, so this seam PROJECTS a deterministic, fully
# synthetic customer turn from the case using the shared Marine::ProductAuthority::SyntheticCaseMessage
# projection — the SAME synthetic turn the acceptance intake adapters already use — so it invents no new
# text and defines no new dataset, then calls the real #extract(text:, context:, state:) and folds the
# untrusted result to EXACTLY the canonical boolean the acceptance surfaces consume.
#
# CANONICAL-SIGNAL semantics (fail-closed): a canonical signal exists ONLY when the extraction returns
# a NORMALIZED product/decision outcome (reason 'extracted' or 'not_product') carrying a boolean
# quantity_inquiry. A DEGRADED extraction (reason 'llm_unconfigured' / 'llm_unavailable' /
# 'malformed_response' / 'llm_error' — the IntentExtractor's unknown_result reasons), a malformed shape,
# or any raised exception yields nil (NO canonical signal). nil is the contract the acceptance surfaces
# interpret as "fall back to the corpus safety metadata": a degraded extraction is never treated as a
# confident `false` that could override a safety=true fallback. #call therefore returns either the
# closed, frozen { source:, quantity_inquiry:, reason_code: } signal hash or nil, and NEVER raises.
#
# It is acceptance-only plumbing. It is NOT wired into any live runtime path, writes NO DB/Redis/
# settings, mutates nothing, and reads no prompts beyond the single call it makes to the real extractor.
# It leaves CandidateGate phase-locked; it activates nothing.
class Marine::ProductAuthority::IntentExtractorSeam
  SyntheticMessage = Marine::ProductAuthority::SyntheticCaseMessage

  # The extraction reasons that are a NORMALIZED product/decision outcome (not a degraded unknown
  # result). Only these carry a trustworthy canonical quantity_inquiry boolean.
  NORMALIZED_REASONS = %w[extracted not_product].freeze

  # Bounded provenance tag for the canonical signal (never a raw value/text).
  SOURCE = 'intent_extractor_seam'

  # intent_extractor: the REAL seam the live path uses (Marine::Catalog::IntentExtractor#extract) or a
  # test/operator-supplied stub responding to #extract. context_builder / state_builder: optional
  # callables projecting a bounded context / safe state hash from the case; absent by default (the
  # synthetic acceptance turn is a single message with no prior context or state).
  def initialize(intent_extractor: Marine::Catalog::IntentExtractor.new, context_builder: nil, state_builder: nil)
    @intent_extractor = intent_extractor
    @context_builder = context_builder
    @state_builder = state_builder
  end

  # Resolve the canonical quantity_inquiry signal for ONE corpus case, or nil when the real seam yields
  # no canonical signal (degraded / malformed / exception). The callable shape (#call(kase)) matches the
  # acceptance surfaces' injected-extractor seam contract.
  def call(kase)
    result = @intent_extractor.extract(
      text: SyntheticMessage.synthetic_message(kase),
      context: @context_builder&.call(kase),
      state: @state_builder&.call(kase)
    )
    canonical(result)
  rescue StandardError
    nil
  end

  private

  # Fold the untrusted extraction result into the closed, frozen signal hash, or nil when there is no
  # canonical signal. A degraded/unknown reason, a non-Hash, or a non-boolean quantity_inquiry all
  # collapse to nil (fail-closed) so the caller falls back to the corpus safety metadata.
  def canonical(result)
    return nil unless result.is_a?(Hash)
    return nil unless NORMALIZED_REASONS.include?(result[:reason])

    quantity = result[:quantity_inquiry]
    return nil unless [true, false].include?(quantity)

    { source: SOURCE, quantity_inquiry: quantity, reason_code: result[:reason] }.freeze
  end
end
