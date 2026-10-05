# Phase 1 (Opsi B) — the SINGLE backend-owned source of truth for execution authorization AND the
# Model 1 Phase-1 classification vocabulary. It is a PURE leaf: it has NO production dependency on any
# other module (not even Marine::Decision::Schema). Its membership inside the Schema vocabulary is a
# spec assertion, never a production alias — nothing else may own a parallel price/capability allowlist.
#
# Scenario no longer carries capabilities: whether the backend may answer a turn is decided here, not
# by scenario configuration. Both Model 1 protocols classify over exactly CLASSIFICATION_INTENTS; the
# adapter / coordinator / planner / packet builder / Model 2 all authorize via #authorized?.
module Marine::Backend::ExecutionPolicy
  # Phase 1: the ONLY executable intents. A frozen, closed vocabulary.
  EXECUTABLE_INTENTS = %w[price].freeze
  # The Phase-1 classification vocabulary offered to Model 1: the executables plus the non-executable
  # fallback. unsupported is classification-only and NEVER authorizes execution.
  CLASSIFICATION_INTENTS = (EXECUTABLE_INTENTS + %w[unsupported]).freeze

  module_function

  # immutable frozen projection
  def executable_intents = EXECUTABLE_INTENTS
  # immutable frozen projection
  def classification_intents = CLASSIFICATION_INTENTS

  # Whole-set authorization (fail closed): the intent set must be the EXACT canonical executable array
  # — NOT a deduped/sorted subset. A duplicated (["price","price"]), reordered, empty, mixed, or
  # non-price set fails, so a malformed direct call can never be normalized into authorization. For
  # Phase 1 this is exactly ["price"].
  def authorized?(intents)
    intents == EXECUTABLE_INTENTS
  end

  # Single-intent membership, for fact-level defense in the planner / packet builder / model2.
  def executable?(intent) = EXECUTABLE_INTENTS.include?(intent)
end
