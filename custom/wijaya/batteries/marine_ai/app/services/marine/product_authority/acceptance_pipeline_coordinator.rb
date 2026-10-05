# frozen_string_literal: true

# Fase 3A-2 — ACCEPTANCE-ONLY coordinator that folds ONE synthetic acceptance case through the real
# Fase 3A-1 backend product pipeline and projects the result into a bounded, closed-schema
# AcceptanceCaseResult:
#
#   normalized Candidate Plan
#     -> exact-quantity precheck (fail closed BEFORE any adapter/planner work)
#     -> Marine::Backend::CandidatePlanToProductIntentAdapter
#     -> Marine::Backend::ProductExecutionPlanner (read-only repository revalidation)
#     -> Marine::Backend::EvidencePacketBuilder
#     -> AcceptanceCaseResult
#
# It is NOT wired into any live runtime path. It is invoked ONLY by a spec or a FUTURE operator-run
# per-case acceptance runner. It NEVER generates or returns reply text, calls a presenter / LLM /
# provider, mutates a Message/Conversation, hands off, assigns, performs an action, delivers, reads
# settings/Redis, or touches ShadowMetricsStore. Candidate authority (CandidateGate) is untouched and
# stays phase-locked.
#
# EXACT QUANTITY: the Candidate Plan schema has no exact-quantity field and is unchanged. The canonical
# legacy extraction already exposes quantity_inquiry; the coordinator accepts that EXACT boolean signal
# as an explicit keyword and NEVER parses customer text itself. When quantity_inquiry is true the case
# fails closed to a blocked result BEFORE the adapter and planner are ever called/invoked.
#
# DEPENDENCY INJECTION: adapter, planner, and evidence builder are injected. The defaults reuse the
# existing implementations — and thereby the planner's DEFAULT read-only repositories — for controlled
# Development acceptance; a spec may inject in-memory fakes for deterministic, DB-free runs.
class Marine::ProductAuthority::AcceptancePipelineCoordinator
  CaseResult = Marine::ProductAuthority::AcceptanceCaseResult
  Outcome = Marine::ProductAuthority::ProductOutcome
  Adapter = Marine::Backend::CandidatePlanToProductIntentAdapter
  Planner = Marine::Backend::ProductExecutionPlanner
  EvidenceBuilder = Marine::Backend::EvidencePacketBuilder
  CandidatePlan = Marine::Decision::CandidatePlan
  InvalidCandidatePlan = Marine::Decision::Errors::InvalidCandidatePlan

  # Safe fallbacks so a malformed case id / surface / outcome can still produce a closed artifact
  # rather than raising.
  SAFE_CASE_ID = 'unknown_case'
  SAFE_SURFACE = 'evaluator'
  SAFE_OUTCOME = { status: Outcome::STATUS_UNKNOWN, intents: [], slot_ops: [], response_goals: [] }.freeze
  BLOCKED_OUTCOME = { status: Outcome::STATUS_BLOCKED, intents: [], slot_ops: [], response_goals: [] }.freeze

  def initialize(adapter: nil, planner: nil, evidence_builder: nil)
    @adapter = adapter || Adapter.new
    @planner = planner || Planner.new
    @evidence_builder = evidence_builder || EvidenceBuilder.new
  end

  def self.run(**)
    new.run(**)
  end

  # candidate_plan:        a normalized (or raw, defensively re-normalized) marine_decision_v1 plan.
  # scenario_key:          the selected scenario key the adapter validates the plan against (String).
  # quantity_inquiry:      the canonical legacy exact-quantity boolean signal (NOT raw text).
  # case_id:               a synthetic, bounded case id.
  # surface:               a controlled acceptance surface (conversation / playground / evaluator).
  # expected_outcome:      the expected normalized outcome { status, intents, slot_ops, response_goals }.
  def run(candidate_plan:, scenario_key:, quantity_inquiry:, case_id:, surface:, expected_outcome:) # rubocop:disable Metrics/ParameterLists -- a flat, named acceptance-case input contract
    expected = CaseResult.normalize_outcome(expected_outcome)
    return malformed_input(case_id, surface, expected) unless valid_inputs?(case_id, surface, quantity_inquiry, expected)

    plan = normalize_plan(candidate_plan)
    return malformed_candidate_plan(case_id, surface, expected) if plan.nil?
    return exact_quantity_blocked(case_id, surface, expected) if quantity_inquiry == true

    execute(plan, scenario_key, case_id, surface, expected)
  rescue StandardError
    internal_error(case_id, surface, expected)
  end

  private

  # The bounded prelude guard: a synthetic case id, a controlled surface, an exact boolean
  # quantity_inquiry signal, and a well-formed expected outcome. Anything else fails closed.
  def valid_inputs?(case_id, surface, quantity_inquiry, expected)
    CaseResult.valid_case_id?(case_id) && CaseResult.valid_surface?(surface) &&
      [true, false].include?(quantity_inquiry) && !expected.nil?
  end

  # Defensively fold ANY input through the canonical candidate-plan contract so a raw / oversized /
  # unknown-key / duplicate-slot plan fails closed to nil. A genuine normalized plan re-normalizes
  # to itself.
  def normalize_plan(candidate_plan)
    CandidatePlan.normalize(candidate_plan)
  rescue InvalidCandidatePlan
    nil
  end

  # Adapter -> Planner -> EvidencePacketBuilder, each translated into a closed stage status and a
  # normalized actual outcome. A blocked adapter short-circuits the planner/builder.
  # -- threads the already-validated case context into the pipeline
  def execute(plan, scenario_key, case_id, surface, expected)
    adapter_result = @adapter.call(plan: plan, scenario_key: scenario_key)
    return adapter_blocked(case_id, surface, expected, adapter_result.reason) unless adapter_result.ok?

    projection = Outcome.project(adapter_result.product_intent)
    evidence_input = run_planner(adapter_result)
    return planner_errored(case_id, surface, expected, projection) if evidence_input.nil?

    actual = actual_outcome(projection, evidence_input[:response_goals])
    evidence_ok = build_evidence(evidence_input)
    completed(case_id, surface, expected, actual, evidence_ok, repository_status(evidence_input))
  end

  # Attest `revalidated` ONLY when the completed planner output proves a successful repository-backed
  # validation — a non-empty validated_slots and/or facts block. A planner completion that validated
  # nothing (a clarification/handoff carrying neither) is attested `not_revalidated` so the status
  # never overclaims. This is attestation only; a correctly expected clarification can still pass.
  def repository_status(evidence_input)
    slots = evidence_input[:validated_slots]
    facts = evidence_input[:facts]
    validated = (slots.is_a?(Hash) && slots.any?) || (facts.is_a?(Hash) && facts.any?)
    validated ? 'revalidated' : 'not_revalidated'
  end

  # Run the planner against its injected read-only repositories; nil on any planner/repository error
  # so the case fails closed rather than leaking an exception.
  def run_planner(adapter_result)
    @planner.call(product_intent: adapter_result.product_intent, intents: adapter_result.intents,
                  scenario: adapter_result.scenario)
  rescue StandardError
    nil
  end

  # true when the planner's evidence input builds into a closed packet; false on a known closed-contract
  # violation. Any OTHER exception propagates to the outer rescue -> internal_error.
  def build_evidence(evidence_input)
    @evidence_builder.build(evidence_input: evidence_input)
    true
  rescue EvidenceBuilder::InvalidEvidenceInputError, EvidenceBuilder::PacketTooLargeError
    false
  end

  # Map the ProductOutcome projection (status/intents/slot_ops) + the planner response goals into the
  # closed normalized outcome shape.
  def actual_outcome(projection, goals)
    { status: projection[:status], intents: projection[:intents], slot_ops: projection[:slot_ops],
      response_goals: Array(goals) }
  end

  # --- terminal result builders (each a closed stage-status combination) -----------------

  def completed(case_id, surface, expected, actual, evidence_ok, repository) # rubocop:disable Metrics/ParameterLists -- a flat projection of validated parts into the closed CaseResult
    reason, passed = verdict(expected, actual, evidence_ok)
    build(case_id, surface, expected, actual,
          candidate_plan: 'valid', exact_quantity: 'clear', adapter: 'accepted', planner: 'planned',
          repository: repository, evidence: evidence_ok ? 'valid' : 'invalid', reason: reason, passed: passed)
  end

  def verdict(expected, actual, evidence_ok)
    return [CaseResult::REASON_EVIDENCE_INVALID, false] unless evidence_ok
    return [CaseResult::REASON_OUTCOME_MISMATCH, false] unless CaseResult.normalize_outcome(actual) == expected

    [CaseResult::REASON_NONE, true]
  end

  def malformed_input(case_id, surface, expected)
    build(case_id, surface, expected || SAFE_OUTCOME, SAFE_OUTCOME,
          candidate_plan: 'skipped', exact_quantity: 'skipped', adapter: 'skipped', planner: 'skipped',
          repository: 'skipped', evidence: 'skipped', reason: CaseResult::REASON_MALFORMED_INPUT, passed: false)
  end

  def malformed_candidate_plan(case_id, surface, expected)
    build(case_id, surface, expected, BLOCKED_OUTCOME,
          candidate_plan: 'malformed', exact_quantity: 'skipped', adapter: 'skipped', planner: 'skipped',
          repository: 'skipped', evidence: 'skipped', reason: CaseResult::REASON_MALFORMED_CANDIDATE_PLAN,
          passed: blocked_pass?(expected))
  end

  def exact_quantity_blocked(case_id, surface, expected)
    build(case_id, surface, expected, BLOCKED_OUTCOME,
          candidate_plan: 'valid', exact_quantity: 'blocked', adapter: 'skipped', planner: 'skipped',
          repository: 'skipped', evidence: 'skipped', reason: CaseResult::EXACT_QUANTITY_REASON,
          passed: blocked_pass?(expected))
  end

  # A blocked adapter may report ONLY an allowlisted adapter reason. An unknown/unexpected reason (a
  # future or injected adapter, or a leaked secret) is NOT trusted as a benign block: the case degrades
  # to a generic internal_error and fails, even when the expected outcome was blocked — an
  # unrecognized authority signal can never be attested as a correct block.
  def adapter_blocked(case_id, surface, expected, reason)
    known = CaseResult::ADAPTER_BLOCK_REASONS.include?(reason)
    build(case_id, surface, expected, BLOCKED_OUTCOME,
          candidate_plan: 'valid', exact_quantity: 'clear', adapter: 'blocked', planner: 'skipped',
          repository: 'skipped', evidence: 'skipped',
          reason: known ? reason : CaseResult::REASON_INTERNAL_ERROR,
          passed: known && blocked_pass?(expected))
  end

  def planner_errored(case_id, surface, expected, projection)
    actual = actual_outcome(projection, [])
    build(case_id, surface, expected, actual,
          candidate_plan: 'valid', exact_quantity: 'clear', adapter: 'accepted', planner: 'errored',
          repository: 'errored', evidence: 'skipped', reason: CaseResult::REASON_PLANNER_ERROR, passed: false)
  end

  def internal_error(case_id, surface, expected)
    build(case_id, surface, expected || SAFE_OUTCOME, SAFE_OUTCOME,
          candidate_plan: 'skipped', exact_quantity: 'skipped', adapter: 'skipped', planner: 'skipped',
          repository: 'skipped', evidence: 'skipped', reason: CaseResult::REASON_INTERNAL_ERROR, passed: false)
  end

  # A blocked-outcome case passes iff the caller expected exactly the blocked outcome.
  def blocked_pass?(expected)
    CaseResult.normalize_outcome(BLOCKED_OUTCOME) == expected
  end

  # Sanitize the case id / surface to a safe fallback so the closed artifact can always be built, then
  # delegate to the fail-closed AcceptanceCaseResult.build.
  def build(case_id, surface, expected, actual, candidate_plan:, exact_quantity:, adapter:, planner:, repository:, evidence:, reason:, passed:) # rubocop:disable Metrics/ParameterLists -- a flat projection of validated parts into the closed CaseResult
    CaseResult.build(
      case_id: CaseResult.valid_case_id?(case_id) ? case_id : SAFE_CASE_ID,
      surface: CaseResult.valid_surface?(surface) ? surface : SAFE_SURFACE,
      candidate_plan_status: candidate_plan,
      exact_quantity_status: exact_quantity,
      adapter_status: adapter,
      planner_status: planner,
      repository_revalidation_status: repository,
      evidence_packet_status: evidence,
      expected_outcome: expected,
      actual_outcome: actual,
      reason: reason,
      passed: passed
    )
  end
end
