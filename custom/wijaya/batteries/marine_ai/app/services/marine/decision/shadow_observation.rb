# PRIVACY-SAFE, IMMUTABLE observation of ONE Marine Decision shadow comparison (Phase 2 /
# Stage 5 — aggregate metrics only). It is built ONLY from the deep-frozen Stage 4
# ShadowExecution result ({ legacy_scenario_key:, candidate_plan: }) plus the account and
# assistant ids, and exposes ONLY aggregate-safe, allowlisted codes:
#
#   * legacy scenario stable key (nil or `scenario_<id>`) and its present/none flag
#   * decision scenario stable key (nil or `scenario_<id>`) and its present/none flag
#   * comparable? (the decision genuinely normalized, not a fallback) and match? (the two
#     stable keys are equal)
#   * the allowlisted outcome reason and confidence codes
#   * the allowlisted candidate intent codes
#   * the (operation, slot) code pairs of the proposed slot operations
#
# It NEVER contains or returns the raw trigger/history, any message/conversation/contact/
# inbox id, the customer_language hint, a slot raw_candidate / candidate_type, a provider
# body/error, any title/description/instruction text, or a record object. Every candidate
# slot value (raw_candidate + candidate_type) is dropped: only the operation and slot codes
# survive. Any malformed input — a non-canonical shape, an out-of-contract code, or a
# scenario key that is not nil / `scenario_<id>` — raises Invalid and is trusted for NOTHING
# (no partial trust). The built object is frozen with frozen members so a caller cannot
# mutate it. It performs NO provider call, settings/DB/Redis access, or state mutation.
class Marine::Decision::ShadowObservation
  Schema = Marine::Decision::Schema
  Config = Marine::Decision::ShadowConfig

  # Raised on ANY malformed input so the caller (ShadowJob) records NOTHING rather than a
  # partially-trusted observation.
  class Invalid < StandardError; end

  attr_reader :account_id, :assistant_id, :legacy_key, :decision_key, :reason, :confidence,
              :intents, :slot_pairs

  def self.build(result:, account_id:, assistant_id:)
    new(result: result, account_id: account_id, assistant_id: assistant_id)
  end

  def initialize(result:, account_id:, assistant_id:)
    raise Invalid unless result.is_a?(Hash)

    @account_id = positive_int!(account_id)
    @assistant_id = positive_int!(assistant_id)
    @legacy_key = stable_key!(result[:legacy_scenario_key])

    plan = result[:candidate_plan]
    raise Invalid unless plan.is_a?(Hash)
    # Only the exact canonical CandidatePlan v1 shape is trusted: a wrong/missing schema
    # version is a non-canonical plan and fails closed with no partial trust.
    raise Invalid unless plan[:schema_version] == Schema::SCHEMA_VERSION

    @reason = allowlisted!(plan[:reason], Schema::REASONS)
    @confidence = allowlisted!(plan[:confidence], Schema::CONFIDENCE_LEVELS)
    @decision_key = stable_key!(scenario_key(plan))
    @intents = intents!(plan[:intents])
    @slot_pairs = slot_pairs!(plan[:slot_operations])
    freeze
  end

  # The decision genuinely produced a normalized plan (not a timeout/provider/malformed
  # fallback), so its scenario choice is meaningful to compare against the legacy selector.
  def comparable?
    @reason == Schema::REASON_NORMALIZED
  end

  # Exact equality of the two stable keys (both `scenario_<id>` or both none). Only meaningful
  # when #comparable?; the metrics store scores agreement/disagreement among comparable samples.
  def match?
    @legacy_key == @decision_key
  end

  def legacy_present?
    !@legacy_key.nil?
  end

  def decision_present?
    !@decision_key.nil?
  end

  private

  # The decision plan's proposed scenario key lives under scenario_candidate[:key]; any other
  # shape is malformed.
  def scenario_key(plan)
    candidate = plan[:scenario_candidate]
    raise Invalid unless candidate.is_a?(Hash)

    candidate[:key]
  end

  def positive_int!(value)
    raise Invalid unless value.is_a?(Integer) && value.positive?

    value
  end

  # nil (none) or a canonical `scenario_<id>` stable key; anything else fails closed. Returns
  # an owned frozen copy so the frozen observation never shares a caller string.
  def stable_key!(value)
    return nil if value.nil?
    raise Invalid unless value.is_a?(String) && value.match?(Config::SCENARIO_KEY_PATTERN)

    value.dup.freeze
  end

  def allowlisted!(value, allowed)
    raise Invalid unless value.is_a?(String) && allowed.include?(value)

    value.dup.freeze
  end

  # Owned, frozen list of allowlisted intent codes; a non-array, an unknown code, an
  # over-bound length, or a DUPLICATE fails closed. A canonical CandidatePlan dedupes intents
  # against Schema::INTENTS, so a repeated code marks a non-canonical plan and is rejected.
  def intents!(value)
    raise Invalid unless value.is_a?(Array) && value.length <= Schema::MAX_INTENTS
    raise Invalid unless value.all? { |code| allowlisted_intent?(code) }
    raise Invalid if value.uniq.length != value.length

    value.map { |code| code.dup.freeze }.freeze
  end

  def allowlisted_intent?(code)
    code.is_a?(String) && Schema::INTENTS.include?(code)
  end

  # Owned, frozen list of [operation, slot] code pairs. The candidate VALUE (raw_candidate +
  # candidate_type) is intentionally never read, so no raw customer string can ride along. A
  # non-array, an out-of-contract operation/slot, or an over-bound length fails closed. Two
  # operations targeting the SAME slot (a duplicate target, and thus any duplicate pair) fail
  # closed too — a canonical CandidatePlan rejects duplicate slots, so a repeat is non-canonical.
  def slot_pairs!(value)
    raise Invalid unless value.is_a?(Array)
    raise Invalid if value.length > Schema::SLOTS.length

    pairs = value.map { |op| slot_pair!(op) }
    slots = pairs.map { |_operation, slot| slot }
    raise Invalid if slots.uniq.length != slots.length

    pairs.freeze
  end

  def slot_pair!(operation)
    raise Invalid unless operation.is_a?(Hash)

    op = allowlisted!(operation[:operation], Schema::SLOT_OPERATIONS)
    slot = allowlisted!(operation[:slot], Schema::SLOTS)
    [op, slot].freeze
  end
end
