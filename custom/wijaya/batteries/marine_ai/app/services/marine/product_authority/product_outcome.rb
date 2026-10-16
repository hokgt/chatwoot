# Fase 3A-2 — PURE, privacy-safe projection of a product-intent outcome into the SINGLE closed
# normalized shape the product shadow compares and scores. It is the one source of truth shared by
# the live ShadowExecution (adapter-only, diagnostic), the ShadowObservation (privacy-safe codes),
# and the deterministic corpus Evaluator, so the three can never drift in how they read an outcome.
#
# It folds an IntentExtractor-shaped product-intent Hash (the shape BOTH the legacy
# Marine::Catalog::IntentExtractor and the Fase 3A-1 CandidatePlanToProductIntentAdapter emit) into
# a bounded { status, intents, slot_ops, requires_exact_variant, quantity_inquiry } Hash of ONLY
# closed-enum codes — never a raw candidate string, family/variant value, customer text, price,
# stock, quantity, id, or provider prose. A raw candidate slot value is reduced to the mere
# presence of a typed slot operation; its content is dropped.
#
# It performs NO provider call, settings/DB/Redis access, or state mutation, and never raises on a
# malformed input — a non-Hash / unknown-shaped input projects to the safe UNKNOWN outcome.
module Marine::ProductAuthority::ProductOutcome
  IntentExtractor = Marine::Catalog::IntentExtractor

  # The product intents that may appear in a normalized outcome (transactional + informational),
  # reused verbatim from the extractor allowlist so the vocabularies can never drift. Canonical
  # array order is the rendering order so a projected set is deterministic.
  INTENTS = IntentExtractor::ALLOWED_PRODUCT_INTENTS

  # Closed intent-level status vocabulary. `blocked` is reserved for a candidate side whose adapter
  # failed closed (no product-intent to project); `unknown` is a failed/unavailable legacy
  # extraction or a malformed input; `not_product` is an explicitly non-product turn.
  STATUS_PRODUCT = 'product'.freeze
  STATUS_OVERVIEW = 'overview'.freeze
  STATUS_UNSUPPORTED = 'unsupported'.freeze
  STATUS_UNKNOWN = 'unknown'.freeze
  STATUS_NOT_PRODUCT = 'not_product'.freeze
  STATUS_BLOCKED = 'blocked'.freeze
  STATUSES = %w[product overview unsupported unknown not_product blocked].freeze

  # Closed typed-slot-operation vocabulary: the mere PRESENCE of a product-family candidate, an
  # exact variant-code candidate, or a natural variant-attribute candidate. The candidate VALUE is
  # never carried.
  SLOT_PRODUCT = 'product'.freeze
  SLOT_VARIANT_CODE = 'variant_code'.freeze
  SLOT_VARIANT_ATTR = 'variant_attr'.freeze
  SLOT_OPS = %w[product variant_code variant_attr].freeze

  module_function

  # The safe unknown outcome (a failed/unavailable extraction or a malformed input).
  def unknown
    { status: STATUS_UNKNOWN, intents: [], slot_ops: [], requires_exact_variant: false, quantity_inquiry: false }.freeze
  end

  # A blocked candidate outcome (the adapter failed closed: no product-intent to project).
  def blocked
    { status: STATUS_BLOCKED, intents: [], slot_ops: [], requires_exact_variant: false, quantity_inquiry: false }.freeze
  end

  # Project an IntentExtractor-shaped product-intent Hash into the closed normalized outcome. A
  # non-Hash / unknown-shaped input folds to #unknown. Deep-frozen; carries only closed codes.
  def project(product_intent)
    return unknown unless product_intent.is_a?(Hash)
    return not_product_outcome unless product_intent[:product_related] == true

    intent = product_intent[:intent]
    {
      status: status_for(intent, product_intent),
      intents: normalized_intents(product_intent[:requested_intents], intent),
      slot_ops: slot_ops_for(product_intent),
      requires_exact_variant: product_intent[:requires_exact_variant] == true,
      quantity_inquiry: product_intent[:quantity_inquiry] == true
    }.freeze
  end

  # A bounded, closed comparison of a legacy outcome against a candidate outcome. Every field is a
  # boolean; no raw value survives. `exact_match` requires intents, slot operations, and status to
  # all agree.
  def compare(legacy, candidate)
    intents_match = legacy[:intents] == candidate[:intents]
    slots_match = legacy[:slot_ops] == candidate[:slot_ops]
    status_match = legacy[:status] == candidate[:status]
    { intents_match: intents_match, slots_match: slots_match, status_match: status_match,
      exact_match: intents_match && slots_match && status_match }.freeze
  end

  def not_product_outcome
    { status: STATUS_NOT_PRODUCT, intents: [], slot_ops: [], requires_exact_variant: false, quantity_inquiry: false }.freeze
  end

  # The intent-level status. An unsupported request or an explicit unsupported intent is
  # `unsupported`; product_overview is `overview`; a supported transactional intent is `product`;
  # anything else (e.g. a non-product/unknown scalar) is `unknown`.
  def status_for(intent, product_intent)
    return STATUS_UNSUPPORTED if product_intent[:unsupported_request] || intent == 'unsupported'
    return STATUS_OVERVIEW if intent == IntentExtractor::PRODUCT_OVERVIEW_INTENT
    return STATUS_PRODUCT if INTENTS.include?(intent)

    STATUS_UNKNOWN
  end

  # The canonical, deduped set of product intents from the requested set plus the scalar primary
  # intent, filtered to the closed product vocabulary and rendered in canonical order. A
  # non-product/unknown intent contributes nothing, so an unsupported/unknown turn yields [].
  def normalized_intents(requested, intent)
    candidates = Array(requested) + [intent]
    INTENTS.select { |code| candidates.include?(code) }.freeze
  end

  # The canonical typed slot-operation set derived from candidate PRESENCE only. A present product
  # family candidate, an exact variant-code candidate, and any natural variant-attribute candidate
  # each contribute their closed token; the candidate content itself is never read.
  def slot_ops_for(product_intent)
    ops = []
    ops << SLOT_PRODUCT if present?(product_intent[:family_mention])
    ops << SLOT_VARIANT_CODE if present?(product_intent[:explicit_child_code])
    ops << SLOT_VARIANT_ATTR if product_intent[:attribute_candidates].is_a?(Array) && !product_intent[:attribute_candidates].empty?
    SLOT_OPS.select { |token| ops.include?(token) }.freeze
  end

  def present?(value)
    value.is_a?(String) && !value.strip.empty?
  end
end
