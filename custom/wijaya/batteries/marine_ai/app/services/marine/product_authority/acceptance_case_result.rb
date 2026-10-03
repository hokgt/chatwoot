# frozen_string_literal: true

# Fase 3A-2 — BOUNDED, CLOSED-SCHEMA per-case acceptance artifact for the product-authority
# pipeline. One AcceptanceCaseResult is the deep-frozen, privacy-safe record the
# AcceptancePipelineCoordinator emits when it folds ONE synthetic acceptance case through the real
# Fase 3A-1 backend pipeline (adapter -> planner -> evidence packet builder). It is an in-memory /
# controlled artifact a FUTURE per-case acceptance runner can collect; it NEVER persists, reads
# settings/Redis/DB, calls a provider, or activates anything.
#
# It is a CLOSED, FAIL-CLOSED contract, not a permissive bag: every field is an enum, a bounded
# synthetic string, or a strictly-normalized closed outcome object drawn ONLY from the existing
# product-outcome / response-goal / adapter-reason vocabularies. It carries NO raw customer text, no
# customer/contact/conversation/message id, no raw provider response, no raw DB row, no exception
# message/class/backtrace, and no arbitrary detail string. `.build` validates every field against the
# closed vocabulary and raises InvalidCaseResult (fail closed) on any violation; the produced instance
# is deeply immutable.
class Marine::ProductAuthority::AcceptanceCaseResult
  Outcome = Marine::ProductAuthority::ProductOutcome
  # Lower-level backend owners this artifact sources its vocabulary from. The artifact is a
  # lower-level dependency than the Evaluator (which will later consume it), so it NEVER references
  # Marine::ProductAuthority::Evaluator.
  Adapter = Marine::Backend::CandidatePlanToProductIntentAdapter
  EvidenceBuilder = Marine::Backend::EvidencePacketBuilder

  SCHEMA_VERSION = 'marine_product_authority_case_result_v1'

  # Closed, minimum-justified controlled acceptance surfaces: the two real product surfaces whose
  # envelopes the parity harness normalizes, plus the evaluator surface this acceptance coordinator
  # serves. No other surface is accepted.
  SURFACES = %w[conversation playground evaluator].freeze

  # Per-stage closed status enums. `skipped` means the stage was never reached because an earlier
  # stage short-circuited (fail-closed) — never that it was silently ignored.
  CANDIDATE_PLAN_STATUSES = %w[valid malformed skipped].freeze
  EXACT_QUANTITY_STATUSES = %w[clear blocked skipped].freeze
  ADAPTER_STATUSES = %w[accepted blocked skipped].freeze
  PLANNER_STATUSES = %w[planned skipped errored].freeze
  # `revalidated` is an attestation that is earned ONLY when the completed planner output carries a
  # repository-backed validated slot or fact; a planner completion that validated nothing (a
  # clarification/handoff with empty validated_slots and facts) uses `not_revalidated` so the
  # attestation never overclaims. `errored` is a planner/repository failure; `skipped` a
  # short-circuit before the planner ever ran.
  REPOSITORY_REVALIDATION_STATUSES = %w[revalidated not_revalidated skipped errored].freeze
  EVIDENCE_PACKET_STATUSES = %w[valid invalid skipped].freeze

  # Normalized-outcome vocabulary, reused verbatim from the shared ProductOutcome projection and the
  # backend EvidencePacketBuilder's response-goal allowlist so the acceptance schema can never drift
  # from the lower pipeline components it scores. An outcome object carries ONLY these closed codes.
  OUTCOME_STATUSES = Outcome::STATUSES
  OUTCOME_INTENTS = Outcome::INTENTS
  OUTCOME_SLOT_OPS = Outcome::SLOT_OPS
  RESPONSE_GOALS = EvidenceBuilder::RESPONSE_GOALS
  OUTCOME_KEYS = %i[status intents slot_ops response_goals].freeze
  MAX_RESPONSE_GOALS = EvidenceBuilder::MAX_RESPONSE_GOALS

  # Closed failure/reason vocabulary: a passing/none sentinel, the coordinator-owned pipeline reasons,
  # the coordinator/acceptance-owned exact-quantity safety reason, and the adapter's allowlisted
  # fail-closed reasons. Opaque codes only — never a raw exception/provider string.
  REASON_NONE = 'none'
  REASON_MALFORMED_INPUT = 'malformed_input'
  REASON_MALFORMED_CANDIDATE_PLAN = 'malformed_candidate_plan'
  REASON_PLANNER_ERROR = 'planner_error'
  REASON_EVIDENCE_INVALID = 'evidence_invalid'
  REASON_OUTCOME_MISMATCH = 'outcome_mismatch'
  REASON_INTERNAL_ERROR = 'internal_error'
  # The exact-quantity safety reason is coordinator/acceptance-owned for THIS phase: its closed code is
  # defined locally so the artifact depends on no higher component for it.
  EXACT_QUANTITY_REASON = 'exact_quantity_request'
  # A compact local allowlist that references the ADAPTER's OWN reason constants (no duplication of the
  # adapter's implementation): the closed fail-closed reasons a blocked adapter may legitimately report.
  ADAPTER_BLOCK_REASONS = [
    Adapter::REASON_UNSUPPORTED_SCHEMA, Adapter::REASON_UNRESOLVED_SCENARIO,
    Adapter::REASON_SCENARIO_MISMATCH, Adapter::REASON_CAPABILITY_UNCONFIGURED,
    Adapter::REASON_CAPABILITY_MALFORMED, Adapter::REASON_CAPABILITY_MISMATCH,
    Adapter::REASON_UNSUPPORTED_INTENT
  ].freeze
  PIPELINE_REASONS = [REASON_NONE, REASON_MALFORMED_INPUT, REASON_MALFORMED_CANDIDATE_PLAN,
                      REASON_PLANNER_ERROR, REASON_EVIDENCE_INVALID, REASON_OUTCOME_MISMATCH,
                      REASON_INTERNAL_ERROR, EXACT_QUANTITY_REASON].freeze
  REASONS = (PIPELINE_REASONS + ADAPTER_BLOCK_REASONS).freeze

  # A synthetic, bounded case id: a short slug of safe characters only. It can carry no customer data.
  CASE_ID_PATTERN = /\A[a-zA-Z0-9_\-]{1,64}\z/

  # Raised (fail closed) when a programmer-supplied field violates the closed contract. Carries a
  # FIXED message only — never the offending value.
  class InvalidCaseResult < StandardError
    def initialize(message = 'The acceptance case result violated the closed schema')
      super
    end
  end

  FIELDS = %i[case_id surface candidate_plan_status exact_quantity_status adapter_status
              planner_status repository_revalidation_status evidence_packet_status
              expected_outcome actual_outcome reason passed].freeze

  attr_reader(*FIELDS)

  # Validate a raw outcome hash into the closed { status, intents, slot_ops, response_goals } shape,
  # or nil when it is malformed / unbounded / out-of-vocabulary. Accepts string or symbol keys.
  # Deep-frozen on success. Never raises.
  def self.normalize_outcome(raw)
    return nil unless raw.is_a?(Hash)

    keyed = symbolize(raw)
    return nil unless exact_outcome_keys?(keyed) && OUTCOME_STATUSES.include?(keyed[:status])

    lists = [closed_list(keyed[:intents], OUTCOME_INTENTS),
             closed_list(keyed[:slot_ops], OUTCOME_SLOT_OPS),
             closed_list(keyed[:response_goals], RESPONSE_GOALS, MAX_RESPONSE_GOALS)]
    return nil if lists.any?(&:nil?)

    { status: keyed[:status].dup.freeze, intents: lists[0], slot_ops: lists[1], response_goals: lists[2] }.freeze
  end

  # Symbolize only String keys (leaves any other key type untouched so an odd key fails the key check).
  def self.symbolize(hash)
    hash.transform_keys { |key| key.is_a?(String) ? key.to_sym : key }
  end

  # Exactly the closed outcome key set, nothing more or less.
  def self.exact_outcome_keys?(hash)
    hash.size == OUTCOME_KEYS.size && OUTCOME_KEYS.all? { |key| hash.key?(key) }
  end

  # A deduped, bounded, closed code list drawn ONLY from `allowed`, or nil when malformed.
  def self.closed_list(value, allowed, max = nil) # rubocop:disable Metrics/CyclomaticComplexity -- a flat sequence of independent closed-list guards
    return nil unless value.is_a?(Array) && value.length <= (max || allowed.length)
    return nil unless value.uniq.length == value.length && value.all? { |code| allowed.include?(code) }

    value.map { |code| code.dup.freeze }.freeze
  end

  def self.valid_case_id?(value)
    value.is_a?(String) && value.match?(CASE_ID_PATTERN)
  end

  def self.valid_surface?(value)
    SURFACES.include?(value)
  end

  # Build a validated, deeply immutable case result. Raises InvalidCaseResult (fail closed) on any
  # closed-contract violation so a malformed programmer call never yields a partly-valid artifact.
  def self.build(**fields) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent closed-field guards
    raise InvalidCaseResult unless (FIELDS - fields.keys).empty? && (fields.keys - FIELDS).empty?
    raise InvalidCaseResult unless valid_case_id?(fields[:case_id])
    raise InvalidCaseResult unless valid_surface?(fields[:surface])
    raise InvalidCaseResult unless CANDIDATE_PLAN_STATUSES.include?(fields[:candidate_plan_status])
    raise InvalidCaseResult unless EXACT_QUANTITY_STATUSES.include?(fields[:exact_quantity_status])
    raise InvalidCaseResult unless ADAPTER_STATUSES.include?(fields[:adapter_status])
    raise InvalidCaseResult unless PLANNER_STATUSES.include?(fields[:planner_status])
    raise InvalidCaseResult unless REPOSITORY_REVALIDATION_STATUSES.include?(fields[:repository_revalidation_status])
    raise InvalidCaseResult unless EVIDENCE_PACKET_STATUSES.include?(fields[:evidence_packet_status])
    raise InvalidCaseResult unless REASONS.include?(fields[:reason])
    raise InvalidCaseResult unless [true, false].include?(fields[:passed])

    expected = normalize_outcome(fields[:expected_outcome])
    actual = normalize_outcome(fields[:actual_outcome])
    raise InvalidCaseResult if expected.nil? || actual.nil?

    new(fields.merge(expected_outcome: expected, actual_outcome: actual))
  end

  # Take sole ownership of every accepted field. Caller-owned scalar String fields (case_id, surface,
  # all stage statuses, reason) are duped and frozen so a later mutation of the caller's source string
  # can never alter this artifact; the already-normalized, deep-frozen outcome hashes and the boolean
  # are stored as-is. The instance itself is then frozen, so a direct field mutation raises FrozenError.
  def initialize(fields)
    FIELDS.each do |field|
      value = fields[field]
      value = value.dup.freeze if value.is_a?(String)
      instance_variable_set("@#{field}", value)
    end
    freeze
  end

  def pass?
    passed == true
  end

  # A deep-frozen, serialization-ready Hash of the closed artifact (schema-tagged). No raw value.
  def to_h
    {
      schema_version: SCHEMA_VERSION,
      case_id: case_id, surface: surface,
      candidate_plan_status: candidate_plan_status,
      exact_quantity_status: exact_quantity_status,
      adapter_status: adapter_status,
      planner_status: planner_status,
      repository_revalidation_status: repository_revalidation_status,
      evidence_packet_status: evidence_packet_status,
      expected_outcome: expected_outcome, actual_outcome: actual_outcome,
      reason: reason, passed: passed
    }.freeze
  end
end
