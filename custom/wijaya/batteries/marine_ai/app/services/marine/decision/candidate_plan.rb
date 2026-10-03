# Public entry point + immutable value factory for the battery-local Marine Decision
# Maker candidate plan (Phase 2 / Stage 1 — structure & normalization ONLY). A candidate
# plan is a bounded, UNTRUSTED suggestion the future Decision Maker may emit; it is never
# backend authority. It can nominate a scenario, candidate (never validated) product/
# variant strings, intent categories, and a customer-language hint — never a validated
# fact, final action, reply text, tool, or SQL (those are rejected upstream as unknown
# fields by the normalizer).
#
# .normalize folds a fully untrusted parsed provider hash into the canonical, DEEP-FROZEN
# candidate-plan v1 shape, or raises Marine::Decision::Errors::InvalidCandidatePlan on any
# contract violation. .unknown builds a safe, deep-frozen fallback plan carrying only an
# allowlisted outcome reason (no raw exception / provider prose), for later runner use on
# a malformed response, unsupported schema, timeout, provider error, or unconfigured
# Decision Maker.
#
# The returned plan is deep-frozen so callers cannot mutate it. This stage performs NO
# provider call, settings read, DB/catalog access, or state mutation and is not wired to
# any runtime hook.
module Marine::Decision::CandidatePlan
  Schema = Marine::Decision::Schema

  module_function

  # Untrusted parsed hash -> canonical, deep-frozen candidate plan, or raises
  # Marine::Decision::Errors::InvalidCandidatePlan. The input hash is never mutated.
  def normalize(raw)
    deep_freeze(Marine::Decision::Normalizer.call(raw))
  end

  # Safe, deep-frozen fallback plan. Carries no scenario/intent/slot authority and only an
  # allowlisted outcome reason; any unrecognized reason folds to 'malformed_response'.
  # Never embeds raw error or provider text.
  def unknown(reason = 'malformed_response')
    deep_freeze(
      schema_version: Schema::SCHEMA_VERSION,
      scenario_candidate: { key: nil, confidence: 'low' },
      intents: [],
      slot_operations: [],
      customer_language: nil,
      confidence: 'low',
      reason: unknown_reason(reason)
    )
  end

  # Fold any input to an allowlisted outcome code, returning a FRESH owned string so
  # deep-freeze never freezes a caller-supplied reason object.
  def unknown_reason(reason)
    code = reason.to_s
    code = 'malformed_response' unless Schema::UNKNOWN_REASONS.include?(code)
    code.dup
  end

  # Recursively freeze the plan and every nested hash/array/string so a caller can never
  # mutate a returned plan in place.
  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end
end
