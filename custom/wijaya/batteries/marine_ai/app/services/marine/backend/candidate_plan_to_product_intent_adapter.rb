# Fase 3A-1 (isolated / mock-only) — the Product Authority Seam adapter (A3-05).
#
# Bridges an UNTRUSTED, bounded Marine Decision Maker candidate plan (marine_decision_v1)
# into the EXISTING backend-owned product-intent input shape (the shape
# Marine::Catalog::IntentExtractor already produces), under two hard authorities the
# runtime does NOT yet enforce at this seam:
#
#   1. EVERY nominated intent must be a SUPPORTED executable product intent
#      (price/stock/parent_info/variant_info/catalog/product_overview — exactly
#      Marine::Catalog::IntentExtractor::ALLOWED_PRODUCT_INTENTS). If ANY intent is
#      order_status/sample/unsupported, the WHOLE plan fails closed — non-product intents
#      are NEVER silently dropped so a mixed price+order_status plan can never execute a
#      partial product action (C1 "intent tak-supported ... ditolak").
#   2. The plan's nominated scenario_candidate.key MUST exactly match the scenario the
#      backend already SELECTED. A plan built under another scenario is never executed
#      for this scenario.
#   3. The carried intents MUST be ExecutionPolicy-authorized (Phase 1 / Opsi B: exactly
#      ["price"]). Execution authorization is backend-policy-owned
#      (Marine::Backend::ExecutionPolicy), NOT derived from scenario — scenario carries no
#      capabilities. A non-price / mixed set fails the WHOLE plan closed
#      (phase_not_executable); no partial product action executes.
#   4. EXACT-code-only variant authority (3A): only a variant_code candidate may become an
#      executable explicit_child_code. A display_label / attribute_value candidate stays
#      visible as an untrusted typed operation but is NEVER promoted to an executable
#      attribute candidate — it leads the planner to clarification, never to repository
#      resolution of a final variant.
#
# This service is PURE: it performs NO provider call, NO settings/installation-config read,
# NO DB/catalog access, NO state read/write, and has ZERO runtime wiring. It never claims a
# validated fact — every slot value stays a CANDIDATE ({raw_candidate, candidate_type}); the
# backend repositories revalidate everything downstream. It returns a deeply immutable
# Result or a closed, allowlisted fail-closed reason — never raw provider prose.
class Marine::Backend::CandidatePlanToProductIntentAdapter
  Schema = Marine::Decision::Schema
  IntentExtractor = Marine::Catalog::IntentExtractor
  ExecutionPolicy = Marine::Backend::ExecutionPolicy

  # The product intents this seam may execute. Exactly the IntentExtractor allowlist
  # (transactional + the informational product_overview); reused so the two can never drift.
  SUPPORTED_INTENTS = IntentExtractor::ALLOWED_PRODUCT_INTENTS
  # The combinable per-turn set (price/stock/parent_info/variant_info/catalog — product_overview
  # never combines), reused from the extractor so the multi-intent contract stays identical.
  COMBINABLE_INTENTS = IntentExtractor::SUPPORTED_PRODUCT_INTENTS

  # The intents that require an EXACT resolved variant before a fact/answer (price/stock/variant_info).
  # requires_exact_variant is set from this so the backend-owned input stays internally consistent.
  EXACT_VARIANT_INTENTS = %w[price stock variant_info].freeze

  # Closed, allowlisted fail-closed reason codes. Opaque; never raw exception/provider text.
  REASON_ACCEPTED = 'accepted'.freeze
  REASON_UNSUPPORTED_SCHEMA = 'unsupported_schema'.freeze
  REASON_UNRESOLVED_SCENARIO = 'unresolved_scenario'.freeze
  REASON_SCENARIO_MISMATCH = 'scenario_mismatch'.freeze
  REASON_UNSUPPORTED_INTENT = 'unsupported_intent'.freeze
  # The Phase-1 execution-policy reject: a supported-but-non-executable intent set (e.g. stock, or a
  # mixed price+stock) that is not the exact ExecutionPolicy-authorized executable array.
  REASON_PHASE_NOT_EXECUTABLE = 'phase_not_executable'.freeze

  # Deeply immutable outcome. `ok?` gates the product-intent input; a fail-closed result
  # carries only a reason code and no authority.
  Result = Struct.new(:ok, :reason, :scenario, :intents, :operations, :product_intent, keyword_init: true) do
    def ok? = ok == true
  end

  # plan:         a normalized marine_decision_v1 candidate plan (or owned equivalent). Re-normalized
  #               defensively so a raw/oversized/malformed/duplicate-slot input fails closed rather
  #               than being trusted.
  # scenario_key: the scenario the backend already SELECTED (String, canonical key).
  # -- a flat sequence of independent fail-closed guards
  def call(plan:, scenario_key:)
    normalized = normalize(plan)
    return failure(REASON_UNSUPPORTED_SCHEMA) if normalized.nil?

    key = scenario_key(scenario_key)
    return failure(REASON_UNRESOLVED_SCENARIO) if key.nil?
    return failure(REASON_SCENARIO_MISMATCH) unless normalized[:scenario_candidate][:key] == key

    intents = normalized[:intents]
    return failure(REASON_UNSUPPORTED_INTENT) if intents.empty?
    # Reject the WHOLE plan if ANY nominated intent is not a supported executable product intent
    # (mixed price+order_status/sample/unsupported never partially executes).
    return failure(REASON_UNSUPPORTED_INTENT) unless (intents - SUPPORTED_INTENTS).empty?
    # Execution authorization is backend-policy-owned: the WHOLE intent set must be the exact
    # ExecutionPolicy-authorized executable array (Phase 1: ["price"]). A supported-but-non-executable
    # set (stock, or a mixed price+stock) fails the whole plan closed — no partial product action.
    return failure(REASON_PHASE_NOT_EXECUTABLE) unless ExecutionPolicy.authorized?(intents)

    accept(normalized, key, supported_in_canonical_order(intents))
  end

  private

  # Defensively fold ANY input through the canonical candidate-plan contract, so a raw,
  # oversized, unknown-key, duplicate-slot, or otherwise malformed plan fails closed to nil.
  # A genuine normalized plan re-normalizes to itself.
  def normalize(plan)
    Marine::Decision::CandidatePlan.normalize(plan)
  rescue Marine::Decision::Errors::InvalidCandidatePlan
    nil
  end

  def scenario_key(value)
    return nil unless value.is_a?(String)

    key = value.strip
    key if key.match?(Schema::SCENARIO_KEY_PATTERN)
  end

  # Project the validated intents through the SUPPORTED_INTENTS allowlist so the carried set is
  # always in the canonical rendering order regardless of the normalizer's ordering.
  def supported_in_canonical_order(intents)
    SUPPORTED_INTENTS.select { |intent| intents.include?(intent) }
  end

  def accept(normalized, key, supported)
    operations = operations(normalized[:slot_operations])
    Result.new(
      ok: true,
      reason: REASON_ACCEPTED,
      scenario: deep_freeze(key: key),
      intents: deep_freeze(supported.dup),
      operations: deep_freeze(operations),
      product_intent: deep_freeze(product_intent(normalized, supported, operations))
    ).freeze
  end

  # Normalize the plan's typed slot operations to a bounded {operation, slot, candidate} form.
  # A `clear` carries no candidate; `set`/`replace` carry the {raw_candidate, candidate_type}
  # candidate verbatim (still never a validated selection).
  def operations(slot_operations)
    slot_operations.map do |op|
      value = op[:value]
      candidate = value && { raw_candidate: value[:raw_candidate], candidate_type: value[:candidate_type] }
      { operation: op[:operation], slot: op[:slot], candidate: candidate }
    end
  end

  # Project the plan into the EXISTING IntentExtractor output contract (same keys, always),
  # deriving only what a bounded candidate plan may supply and defaulting every field the
  # plan cannot assert to its safe unknown value. Carries NO Model 1 prose (clarification_reply
  # stays nil) and NO validated fact.
  def product_intent(normalized, supported, operations)
    product_op = operation_for(operations, 'product')
    variant_op = operation_for(operations, 'variant_input')
    base_product_intent(normalized, supported).merge(
      family_mention: candidate_of(product_op),
      explicit_child_code: variant_code_candidate(variant_op),
      attribute_candidates: attribute_candidates(variant_op)
    )
  end

  # Every field the plan cannot supply defaults to its safe unknown value; no validated fact and
  # no Model 1 prose (clarification_reply stays nil) is ever carried.
  def base_product_intent(normalized, supported)
    {
      product_related: true,
      intent: supported.first,
      requested_intents: COMBINABLE_INTENTS.select { |intent| supported.include?(intent) },
      requires_exact_variant: supported.intersect?(EXACT_VARIANT_INTENTS),
      clarification_reply: nil,
      family_changed: false,
      intent_changed: false,
      intent_scope: nil,
      multiple_numeric_candidates: false,
      quantity_inquiry: false,
      unsupported_request: nil,
      confidence: normalized[:confidence],
      customer_language: normalized[:customer_language],
      reason: 'extracted'
    }
  end

  # The single set/replace operation for a slot (a clear or absent slot yields nil). Duplicate
  # slot mutations were already rejected fail-closed by the normalizer.
  def operation_for(operations, slot)
    operations.find { |op| op[:slot] == slot && op[:candidate] }
  end

  def candidate_of(operation)
    operation && operation[:candidate][:raw_candidate]
  end

  # A variant_code candidate becomes the explicit child-code candidate; a display_label /
  # attribute_value candidate does not (it flows through attribute_candidates instead).
  def variant_code_candidate(operation)
    return nil unless operation
    return nil unless operation[:candidate][:candidate_type] == 'variant_code'

    operation[:candidate][:raw_candidate]
  end

  # EXACT-code-only variant authority (3A-1): a display_label / attribute_value candidate is
  # NEVER promoted to an executable attribute candidate. It stays visible in `operations` as an
  # untrusted typed operation, but attribute_candidates is always empty so the planner resolves
  # a variant ONLY from an exact child code — a display/attribute candidate leads to
  # clarification, never repository resolution of a final variant.
  def attribute_candidates(_operation)
    []
  end

  def failure(reason)
    Result.new(ok: false, reason: reason, scenario: nil, intents: nil, operations: nil, product_intent: nil).freeze
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end
end
