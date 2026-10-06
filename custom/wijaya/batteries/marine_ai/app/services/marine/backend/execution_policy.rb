# Phase 1 (Opsi B) — the SINGLE backend-owned source of truth for execution authorization AND the
# Model 1 Phase-1 classification vocabulary. It is a PURE leaf: it has NO production dependency on any
# other module (not even Marine::Decision::Schema). Its membership inside the Schema vocabulary is a
# spec assertion, never a production alias — nothing else may own a parallel price/capability allowlist.
#
# Scenario no longer carries capabilities: whether the backend may answer a turn is decided here, not
# by scenario configuration. Both Model 1 protocols classify over exactly CLASSIFICATION_INTENTS; the
# adapter / coordinator / planner / packet builder / Model 2 all authorize via #authorized?.
module Marine::Backend::ExecutionPolicy
  # Phase 1: the ONLY intent the LIVE price bridge executes. Kept exactly ["price"] so every live
  # price-path gate (adapter / coordinator / Model 2 shadow / exact-price execution) is unchanged by
  # the Phase 3 product-packet additions below — #authorized? still means exactly ["price"].
  EXECUTABLE_INTENTS = %w[price].freeze

  # Phase 3/5: the backend catalog-authority product intents the isolated Evidence-packet path
  # (EvidencePacketBuilder / ProductExecutionPlanner) may execute, each as a SINGLE-intent set only.
  # price is included so the exact-price packet is unchanged; product_listing and product_information
  # are the bounded-catalog reads; price_range (Phase 5) is the family-level selling-price range and
  # stock (Phase 5) is the binary availability read. These are NOT wired into the live price bridge
  # (the EXECUTABLE_INTENTS == ["price"] contract above is unchanged).
  PRODUCT_INTENTS = %w[price price_range stock product_listing product_information].freeze

  # The classification vocabulary offered to Model 1: every executable product intent plus the
  # non-executable fallback. unsupported is classification-only and NEVER authorizes execution.
  CLASSIFICATION_INTENTS = (PRODUCT_INTENTS + %w[unsupported]).freeze

  # The exact authorized single-intent sets for the Phase 3 product-packet path — each executable
  # product intent as its own one-element array. Membership is #product_authorized? below.
  PRODUCT_INTENT_SETS = PRODUCT_INTENTS.map { |intent| [intent].freeze }.freeze

  module_function

  # immutable frozen projection
  def executable_intents = EXECUTABLE_INTENTS
  # immutable frozen projection
  def product_intents = PRODUCT_INTENTS
  # immutable frozen projection
  def classification_intents = CLASSIFICATION_INTENTS

  # Live price-bridge authorization (fail closed, UNCHANGED): the intent set must be the EXACT
  # canonical executable array — NOT a deduped/sorted subset. A duplicated (["price","price"]),
  # reordered, empty, mixed, or non-price set fails, so a malformed direct call can never be
  # normalized into authorization. For Phase 1 this is exactly ["price"].
  def authorized?(intents)
    intents == EXECUTABLE_INTENTS
  end

  # Phase 3/5 product-packet authorization (fail closed): the intent set must be exactly ONE executable
  # product intent, as a single-element array — ["price"], ["price_range"], ["stock"],
  # ["product_listing"], or ["product_information"]. A deduped/reordered/mixed/empty set or a non-array
  # fails closed, so the Evidence packet can never be built over anything but a single authorized
  # product intent. ["price"] still passes, so the exact-price packet is unchanged.
  def product_authorized?(intents)
    PRODUCT_INTENT_SETS.include?(intents)
  end

  # Single-intent membership, for fact-level defense in the planner / packet builder / model2.
  def executable?(intent) = EXECUTABLE_INTENTS.include?(intent)

  # Single-intent membership across the Phase 3 product intents (fact-level defense on the packet path).
  def product_executable?(intent) = PRODUCT_INTENTS.include?(intent)
end
