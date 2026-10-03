# Fase 3A-2 — PRIVACY-SAFE, IMMUTABLE observation of ONE product-authority shadow comparison. It is
# built ONLY from the deep-frozen ShadowExecution result ({ legacy:, candidate:, comparable: }) plus
# the account and assistant ids, and exposes ONLY aggregate-safe, allowlisted codes:
#
#   * legacy / candidate normalized status codes,
#   * comparable? (the Decision genuinely normalized a plan), and the intent/slot/status/exact
#     agreement flags (meaningful only when comparable),
#   * the allowlisted legacy / candidate intent codes and typed slot-operation codes,
#   * the critical-safety quantity_inquiry flags (exact stock quantity must fail closed to handoff).
#
# It NEVER contains or returns the raw trigger/history, any message/conversation/contact/inbox id, a
# family/variant/candidate raw value, a price/stock/quantity, a provider body/error, any title/
# description/instruction text, prompts, chain-of-thought, or a record object. Every candidate slot
# value is already reduced by ProductOutcome to a mere typed-operation code. Any malformed input — a
# non-canonical shape, an out-of-contract code, a duplicate, or an over-bound set — raises Invalid and
# is trusted for NOTHING (no partial trust). The built object is frozen with frozen members. It
# performs NO provider call, settings/DB/Redis access, or state mutation.
class Marine::ProductAuthority::ShadowObservation
  Outcome = Marine::ProductAuthority::ProductOutcome

  # Raised on ANY malformed input so the caller (ShadowJob) records NOTHING rather than a
  # partially-trusted observation.
  class Invalid < StandardError; end

  # The exact key set each normalized outcome must carry (the ProductOutcome contract).
  OUTCOME_KEYS = %i[status intents slot_ops requires_exact_variant quantity_inquiry].freeze

  attr_reader :account_id, :assistant_id, :legacy, :candidate, :comparison

  def self.build(result:, account_id:, assistant_id:)
    new(result: result, account_id: account_id, assistant_id: assistant_id)
  end

  def initialize(result:, account_id:, assistant_id:)
    raise Invalid unless result.is_a?(Hash)

    @account_id = positive_int!(account_id)
    @assistant_id = positive_int!(assistant_id)
    @comparable = result[:comparable] == true
    @legacy = outcome!(result[:legacy])
    @candidate = outcome!(result[:candidate])
    @comparison = Outcome.compare(@legacy, @candidate)
    freeze
  end

  # The Decision genuinely produced a normalized plan, so its product outcome is meaningful to
  # compare against the legacy extractor. Only comparable samples score agreement.
  def comparable?
    @comparable
  end

  def exact_match?    = @comparison[:exact_match]
  def intents_match?  = @comparison[:intents_match]
  def slots_match?    = @comparison[:slots_match]
  def status_match?   = @comparison[:status_match]

  def legacy_status = @legacy[:status]
  def candidate_status = @candidate[:status]
  def legacy_intents = @legacy[:intents]
  def candidate_intents = @candidate[:intents]
  def legacy_slot_ops = @legacy[:slot_ops]
  def candidate_slot_ops = @candidate[:slot_ops]
  def legacy_quantity_inquiry? = @legacy[:quantity_inquiry]
  def candidate_quantity_inquiry? = @candidate[:quantity_inquiry]

  private

  # A closed, owned copy of one normalized outcome. The exact key set, a status in the closed
  # vocabulary, unique bounded intent/slot codes, and boolean flags are all required; anything else
  # fails closed.
  def outcome!(outcome)
    raise Invalid unless outcome.is_a?(Hash)
    raise Invalid unless outcome.keys.sort == OUTCOME_KEYS.sort
    raise Invalid unless Outcome::STATUSES.include?(outcome[:status])

    {
      status: outcome[:status].dup.freeze,
      intents: codes!(outcome[:intents], Outcome::INTENTS),
      slot_ops: codes!(outcome[:slot_ops], Outcome::SLOT_OPS),
      requires_exact_variant: bool!(outcome[:requires_exact_variant]),
      quantity_inquiry: bool!(outcome[:quantity_inquiry])
    }.freeze
  end

  # Owned, frozen list of allowlisted codes; a non-array, an unknown code, a DUPLICATE, or an
  # over-bound length (more than the whole vocabulary) fails closed.
  def codes!(value, allowed)
    raise Invalid unless bounded_code_array?(value, allowed)
    raise Invalid unless value.all? { |code| allowed_code?(code, allowed) }
    raise Invalid unless unique?(value)

    value.map { |code| code.dup.freeze }.freeze
  end

  # An array no longer than the whole vocabulary.
  def bounded_code_array?(value, allowed)
    value.is_a?(Array) && value.length <= allowed.length
  end

  # A String drawn from the allowlist.
  def allowed_code?(code, allowed)
    code.is_a?(String) && allowed.include?(code)
  end

  # No duplicate entries.
  def unique?(value)
    value.uniq.length == value.length
  end

  def bool!(value)
    raise Invalid unless value == true || value == false

    value
  end

  def positive_int!(value)
    raise Invalid unless value.is_a?(Integer) && value.positive?

    value
  end
end
