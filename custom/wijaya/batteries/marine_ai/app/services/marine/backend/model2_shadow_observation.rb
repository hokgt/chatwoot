# Langkah 3 observability — PRIVACY-SAFE, IMMUTABLE projection of ONE Model 2 shadow result. It is
# built ONLY from the deep-frozen Marine::Backend::Model2ShadowExecution::Result and exposes ONLY the
# two closed aggregate-safe codes that Result already carries:
#
#   * the closed status (:accepted | :rejected | :skipped)
#   * the closed reason (the execution's own REASON_* / PRESENTER_REASON vocabulary)
#
# It REUSES Model2ShadowExecution's existing status/reason constants (it invents no new vocabulary)
# and trusts ONLY an exact (status, reason) pair the execution can genuinely emit — ALLOWED_PAIRS is
# derived directly from those constants. Any other input — a non-Result object (a Hash, a broad
# payload, the generated text), an unknown status, an out-of-contract reason, or an impossible pair —
# raises Invalid and is trusted for NOTHING (no partial trust), so the caller records nothing.
#
# It NEVER contains or returns the generated text, the Evidence Packet, a Candidate Plan, Model 1
# output, a variant/product code, a price/currency/UOM, any conversation/contact/account/assistant/
# message id, a prompt, a provider body/error, or a record object: Result carries none of these, and
# this projection reads ONLY #status and #reason. The built object is frozen. It performs NO provider
# call, settings/DB/Redis access, or state mutation.
class Marine::Backend::Model2ShadowObservation
  Execution = Marine::Backend::Model2ShadowExecution

  # Raised on ANY malformed input so the caller (ShadowJob) records NOTHING rather than a
  # partially-trusted observation.
  class Invalid < StandardError; end

  # The exact, fully-enumerated (status => reasons) contract, built from the execution's OWN
  # constants so this projection can never drift from the vocabulary the execution emits:
  #   accepted  -> deliverable_wording
  #   rejected  -> the presenter's mapped reasons + internal_error
  #   skipped   -> relationship_invalid | not_exact_price | invalid_packet
  ALLOWED_PAIRS = {
    Execution::STATUS_ACCEPTED => [Execution::REASON_DELIVERABLE_WORDING].freeze,
    Execution::STATUS_REJECTED => (Execution::PRESENTER_REASON.values + [Execution::REASON_INTERNAL_ERROR]).uniq.freeze,
    Execution::STATUS_SKIPPED => [
      Execution::REASON_RELATIONSHIP_INVALID,
      Execution::REASON_NOT_EXACT_PRICE,
      Execution::REASON_INVALID_PACKET
    ].freeze
  }.freeze

  attr_reader :status, :reason

  def self.build(result:)
    new(result: result)
  end

  def initialize(result:)
    # Only a genuine deep-frozen Model2ShadowExecution::Result is trusted — never a Hash, a broad
    # payload, or the generated text — so no forbidden field can ride in behind a look-alike object.
    raise Invalid unless result.is_a?(Execution::Result)

    status = result.status
    reason = result.reason
    # The pair must be one the execution can genuinely emit; anything else fails closed.
    raise Invalid unless ALLOWED_PAIRS[status]&.include?(reason)

    @status = status
    @reason = reason
    freeze
  end
end
