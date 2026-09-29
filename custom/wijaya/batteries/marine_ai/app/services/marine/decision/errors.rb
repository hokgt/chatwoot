# Sanitized errors for the battery-local Marine Decision Maker candidate-plan
# contract (Phase 2 / Stage 1 — structure & normalization ONLY). The raw provider
# response is fully untrusted; when it cannot be folded into the strict, bounded
# candidate-plan v1 shape the normalizer fails closed with InvalidCandidatePlan.
#
# The error carries a FIXED, allowlisted message only. It NEVER embeds raw provider
# prose, chain-of-thought, exception text, or the offending value, so no untrusted
# content ever rides out on the error. Callers translate it into a safe unknown plan
# (see Marine::Decision::CandidatePlan.unknown) rather than surfacing provider detail.
module Marine::Decision::Errors
  class DecisionError < StandardError; end

  # Raised when untrusted candidate-plan input violates the v1 contract:
  # malformed structure/types, unknown top-level or nested keys, unknown enum
  # values, out-of-bounds length/cardinality, control characters, duplicate slot
  # operations, or an incompatible clear/value shape. Fail closed with no detail.
  class InvalidCandidatePlan < DecisionError
    def initialize(message = 'The decision candidate plan could not be normalized')
      super
    end
  end
end
