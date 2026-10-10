# Pure mapper from an EXISTING, frozen Marine::Backend::ProductStateTransition::Result onto the closed
# proposed-state-transition operation enum the finalize seam applies (:start / :update). It wires the
# previously-isolated ProductStateTransition helper into the price_range authority WITHOUT broadening it:
# it reads only the already-computed Result's schema/operation and NEVER touches a repository, the state
# store, or a provider.
#
# Mapping (fail-closed): ProductStateTransition PRODUCT_REPLACEMENT -> :start (a fresh/switched/expired
# family clears the stale variant/catalog state), VARIANT_REPLACEMENT -> :update (the same active family
# is refined). Every other input — nil, a wrong class, a mismatched schema_version, an unknown operation,
# or a mutable (non-frozen) Result — maps to nil so a forged/malformed transition can never drive a write.
class Marine::Backend::StateTransitionAdapter
  ProductStateTransition = Marine::Backend::ProductStateTransition

  OPERATION_MAP = {
    ProductStateTransition::PRODUCT_REPLACEMENT => :start,
    ProductStateTransition::VARIANT_REPLACEMENT => :update
  }.freeze

  # Returns :start / :update for a valid frozen ProductStateTransition::Result, else nil (fail closed).
  def call(result)
    return nil unless result.is_a?(ProductStateTransition::Result)
    return nil unless result.frozen?
    return nil unless result.schema_version == ProductStateTransition::SCHEMA_VERSION

    OPERATION_MAP[result.operation]
  end
end
