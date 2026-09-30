# Fase 3A-1 (isolated / mock-only) — pure PROPOSED product-flow state transition.
#
# Computes the state INVALIDATION a product- or variant-replacement implies, using the
# REAL Marine::Catalog::ProductFlowStateStore field names (A6-01) and the store's own
# in-memory #apply_snapshot twin — so it proves the transition against the exact
# allowlist/bounds/lifecycle of the persisted path WITHOUT ever taking a row lock or
# writing live state. There is NO persistence, NO conversation, and NO runtime wiring.
#
# Invalidation rules (A6-01):
#   * PRODUCT replacement clears the variant-dependent state (validated_variant,
#     expected_attributes, clarification_kind/count/family_codes) AND the catalog metadata
#     (catalog_sent, catalog_document_id, catalog_message_id).
#   * VARIANT replacement clears only the variant-dependent state.
#   * current_intent / requested_intents are NEVER cleared here; a caller preserves a
#     still-valid intent by simply not overriding it (they carry through the merge).
#
# schema_version is a SEPARATE metadata field (default 1), distinct from the store's
# revision `version` counter — no migration, no change to the store's version semantics.
class Marine::Backend::ProductStateTransition
  Store = Marine::Catalog::ProductFlowStateStore

  # Additive contract schema version, tracked separately from the store's revision `version`.
  SCHEMA_VERSION = 1

  PRODUCT_REPLACEMENT = :product_replacement
  VARIANT_REPLACEMENT = :variant_replacement
  KINDS = [PRODUCT_REPLACEMENT, VARIANT_REPLACEMENT].freeze

  # Variant-dependent state cleared on BOTH a product and a variant replacement.
  VARIANT_DEPENDENT_KEYS = %w[
    validated_variant expected_attributes
    clarification_kind clarification_count clarification_family_codes
  ].freeze
  # Catalog metadata additionally cleared only when the PRODUCT itself changes.
  CATALOG_KEYS = %w[catalog_sent catalog_document_id catalog_message_id].freeze
  PRODUCT_REPLACEMENT_KEYS = (VARIANT_DEPENDENT_KEYS + CATALOG_KEYS).freeze

  # Only these caller-supplied fields may be SET alongside the invalidation (the store
  # allowlists again). validated_family/current_intent/requested_intents let a caller
  # establish the replacing product and preserve a still-valid intent.
  SETTABLE_KEYS = %w[validated_family current_intent requested_intents original_intent].freeze

  Result = Struct.new(:schema_version, :operation, :invalidated_keys, :changes, :snapshot, keyword_init: true) do
    def to_h
      { schema_version: schema_version, operation: operation, invalidated_keys: invalidated_keys,
        changes: changes, snapshot: snapshot }
    end
  end

  def initialize(store: nil)
    # A store bound to conversation: nil supports ONLY the in-memory snapshot twins.
    @store = store || Store.new(conversation: nil)
  end

  # existing: the prior product_flow snapshot (Hash) or nil for a fresh flow.
  # kind:     :product_replacement | :variant_replacement.
  # set:      optional caller fields to establish (validated_family, current_intent, ...).
  #
  # Fails closed (ArgumentError) on an unknown kind, a non-Hash set, an unknown set key, or a
  # product replacement without a nonblank validated_family replacement — a product replacement
  # must establish the NEW family, never silently retain the old one.
  def call(existing:, kind:, set: {})
    raise ArgumentError, "unknown transition kind: #{kind}" unless KINDS.include?(kind)

    settable = settable(set)
    if kind == PRODUCT_REPLACEMENT && blank?(settable['validated_family'])
      raise ArgumentError, 'product replacement requires a nonblank validated_family replacement'
    end

    keys = kind == PRODUCT_REPLACEMENT ? PRODUCT_REPLACEMENT_KEYS : VARIANT_DEPENDENT_KEYS
    changes = deep_freeze(invalidation_changes(keys).merge(settable))
    snapshot = deep_freeze(@store.apply_snapshot(existing, operation: :update, changes: changes))

    Result.new(schema_version: SCHEMA_VERSION, operation: kind,
               invalidated_keys: keys.dup.freeze, changes: changes, snapshot: snapshot).freeze
  end

  private

  # Each invalidated key is cleared: expected_attributes to an empty list, every other to nil
  # (the store drops a nil optional field on read, so the value no longer persists).
  def invalidation_changes(keys)
    keys.index_with do |key|
      key == 'expected_attributes' ? [] : nil
    end
  end

  # A caller may only SET the allowlisted establishing fields. A non-Hash set or any unknown key
  # fails closed rather than being silently ignored (the store then allowlists again as a second
  # boundary).
  def settable(set)
    raise ArgumentError, 'set must be a Hash' unless set.is_a?(Hash)

    stringified = set.transform_keys(&:to_s)
    unknown = stringified.keys - SETTABLE_KEYS
    raise ArgumentError, "unknown set keys: #{unknown.join(', ')}" unless unknown.empty?

    stringified
  end

  def blank?(value)
    value.to_s.strip.empty?
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end
end
