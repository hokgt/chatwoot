# Phase 2A (PRICE-ONLY shadow bridge) — the closing seam between the already-computed, UNTRUSTED
# JEV CandidatePlan and the Backend Authority. It is reached ONLY from the read-only
# AuthorityShadowExecution, inside the default-OFF Decision shadow, and produces NO customer output:
# it stops at a bounded, deep-frozen Result describing the evidence INPUT / range / terminal outcome
# a later phase would act on.
#
# Pipeline (all read-only; every step fails closed):
#   1. CandidatePlanToProductIntentAdapter authorizes the plan's schema/scenario/intent/capability
#      (its Result is NEVER mutated).
#   2. The technical PRICE-ONLY allowlist is enforced: the authorized intent set must be EXACTLY
#      ["price"]. Every other single intent and every multi-intent (incl. price+stock) returns
#      legacy_preserved/phase_not_executable BEFORE any fact repository call — StockRepository is
#      never reached.
#   3. CatalogCandidateResolver grounds the exact catalog identity from the current trigger + the
#      read-only flow-state snapshot (§7.3/§7.4 precedence).
#   4. ConversationLanguageResolver fixes the delivery language BEFORE the planner; a nil language on
#      an exact-price turn fails closed to handoff/language_unresolved (no silent EN/ID default).
#   5. A FRESH IntentExtractor-shaped planner input is built ONLY from the resolver / revalidated
#      state / language resolver — JEV slot_operations never source an identifier.
#   6. Dispatch: exact family + child → ProductExecutionPlanner → EvidencePacketBuilder
#      (evidence_packet); exact family only → FamilyPriceRangeAuthority (family_price_range);
#      ambiguity → clarify; outage → handoff; no exact catalog match → legacy_preserved.
#
# The Result carries only closed enums + at most one of evidence_packet/price_range (both already
# deep-frozen by their builders). It never carries raw text, DB rows, product lists, provider prose,
# or a mutable object.
class Marine::Backend::AuthorityCoordinator
  Adapter = Marine::Backend::CandidatePlanToProductIntentAdapter
  Resolver = Marine::Backend::CatalogCandidateResolver

  # The technical PRICE-ONLY execution allowlist (a gate, NOT a business mapping): the authorized
  # intent set must equal this exactly before any fact repository is touched.
  PRICE_ONLY = %w[price].freeze

  OUTCOME_EVIDENCE_PACKET = :evidence_packet
  OUTCOME_FAMILY_PRICE_RANGE = :family_price_range
  OUTCOME_CLARIFY = :clarify
  OUTCOME_HANDOFF = :handoff
  OUTCOME_LEGACY_PRESERVED = :legacy_preserved
  OUTCOME_STOP = :stop

  SOURCE_NONE = :none

  REASON_ACCEPTED = :accepted
  REASON_CAPABILITY_UNCONFIGURED = :capability_unconfigured
  REASON_CAPABILITY_MISMATCH = :capability_mismatch
  REASON_PHASE_NOT_EXECUTABLE = :phase_not_executable
  REASON_SCENARIO_MISMATCH = :scenario_mismatch
  REASON_UNSUPPORTED_PLAN = :unsupported_plan
  REASON_CANDIDATE_CONTEXT_INSUFFICIENT = :candidate_context_insufficient
  REASON_FAMILY_AMBIGUOUS = :family_ambiguous
  REASON_VARIANT_AMBIGUOUS = :variant_ambiguous
  REASON_CATALOG_UNAVAILABLE = :catalog_unavailable
  REASON_LANGUAGE_UNRESOLVED = :language_unresolved
  REASON_PRICE_UNAVAILABLE = :price_unavailable
  REASON_RANGE_UNAVAILABLE = :range_unavailable
  REASON_INTERNAL_ERROR = :internal_error

  # Adapter fail-closed reason → coordinator (outcome_type, reason). unresolved_scenario /
  # scenario_mismatch / unsupported_schema are terminal stops; a capability anomaly or an
  # out-of-price intent preserves legacy. A malformed capability map is treated like an
  # unconfigured one (both fail closed to capability_unconfigured in §8).
  ADAPTER_FAILURE = {
    Adapter::REASON_UNSUPPORTED_SCHEMA => [OUTCOME_STOP, REASON_UNSUPPORTED_PLAN],
    Adapter::REASON_UNRESOLVED_SCENARIO => [OUTCOME_STOP, REASON_SCENARIO_MISMATCH],
    Adapter::REASON_SCENARIO_MISMATCH => [OUTCOME_STOP, REASON_SCENARIO_MISMATCH],
    Adapter::REASON_UNSUPPORTED_INTENT => [OUTCOME_STOP, REASON_UNSUPPORTED_PLAN],
    Adapter::REASON_CAPABILITY_UNCONFIGURED => [OUTCOME_LEGACY_PRESERVED, REASON_CAPABILITY_UNCONFIGURED],
    Adapter::REASON_CAPABILITY_MALFORMED => [OUTCOME_LEGACY_PRESERVED, REASON_CAPABILITY_UNCONFIGURED],
    Adapter::REASON_CAPABILITY_MISMATCH => [OUTCOME_LEGACY_PRESERVED, REASON_CAPABILITY_MISMATCH]
  }.freeze

  # Planner response goal → clarify reason (a planner-produced clarify may still carry its packet).
  CLARIFY_REASON = {
    'clarify_product' => REASON_FAMILY_AMBIGUOUS,
    'clarify_variant' => REASON_VARIANT_AMBIGUOUS,
    'clarify_ambiguous_variant' => REASON_VARIANT_AMBIGUOUS
  }.freeze

  # Closed, deep-frozen coordinator outcome. At most one of evidence_packet/price_range is present;
  # both are already deep-frozen by their builders.
  Result = Struct.new(:outcome_type, :reason, :scenario_key, :intents, :source,
                      :evidence_packet, :price_range, keyword_init: true) do
    def evidence_packet? = !evidence_packet.nil?
    def price_range? = !price_range.nil?
  end

  # A deep-frozen terminal stop Result (no scenario/intents/source), reused by AuthorityShadowExecution
  # for the plan-confidence / scenario-resolution failures it gates BEFORE the coordinator runs.
  def self.stop(reason:)
    Result.new(outcome_type: OUTCOME_STOP, reason: reason, scenario_key: nil,
               intents: [].freeze, source: SOURCE_NONE).freeze
  end

  def initialize(adapter: nil, resolver: nil, planner: nil, packet_builder: nil, # rubocop:disable Metrics/ParameterLists -- injected read-only collaborators (all optional)
                 range_authority: nil, language_resolver: nil)
    @adapter = adapter || Adapter.new
    @resolver = resolver || Resolver.new
    @planner = planner || Marine::Backend::ProductExecutionPlanner.new
    @packet_builder = packet_builder || Marine::Backend::EvidencePacketBuilder.new
    @range_authority = range_authority || Marine::Backend::FamilyPriceRangeAuthority.new
    @language_resolver = language_resolver || Marine::Catalog::ConversationLanguageResolver
  end

  # phase is part of the ContextBuilder handoff contract (§7.5) and reserved for the planner-input
  # phase semantics; it is carried through for provenance but not consumed in the price-only 2A slice.
  def call(candidate_plan:, scenario_key:, scenario_capabilities:, trigger:, history:, phase:, flow_state:, configured_language:) # rubocop:disable Lint/UnusedMethodArgument,Metrics/ParameterLists -- documented §7.5 closed signature
    authorized = @adapter.call(plan: candidate_plan, scenario_key: scenario_key, scenario_capabilities: scenario_capabilities)
    return adapter_failure(authorized.reason, scenario_key) unless authorized.ok?
    return phase_not_executable(authorized) unless authorized.intents == PRICE_ONLY

    resolved = @resolver.call(trigger: trigger, flow_state: flow_state)
    dispatch(authorized, resolved, trigger: trigger, history: history,
                                   configured_language: configured_language)
  rescue StandardError
    self.class.stop(reason: REASON_INTERNAL_ERROR)
  end

  private

  # Route an exact catalog identity into the price branch, or fail closed per the resolver status.
  # Every closed resolver status is handled EXPLICITLY; an unknown/malformed status fails closed to
  # stop/internal_error (it must NEVER fall through to the family range).
  def dispatch(authorized, resolved, trigger:, history:, configured_language:)
    case resolved.status
    when Resolver::STATUS_EXACT_FAMILY, Resolver::STATUS_EXACT_CHILD
      with_language(authorized, resolved, trigger: trigger, history: history,
                                          configured_language: configured_language)
    when Resolver::STATUS_UNAVAILABLE
      terminal(OUTCOME_HANDOFF, REASON_CATALOG_UNAVAILABLE, authorized, resolved)
    when Resolver::STATUS_AMBIGUOUS
      terminal(OUTCOME_CLARIFY, resolved.reason, authorized, resolved)
    when Resolver::STATUS_NO_CATALOG_MATCH
      terminal(OUTCOME_LEGACY_PRESERVED, REASON_CANDIDATE_CONTEXT_INSUFFICIENT, authorized, resolved)
    else
      self.class.stop(reason: REASON_INTERNAL_ERROR)
    end
  end

  # Resolve the delivery language BEFORE the planner; a nil language fails closed factless.
  def with_language(authorized, resolved, trigger:, history:, configured_language:)
    language = resolve_language(resolved, trigger: trigger, history: history, configured_language: configured_language)
    return terminal(OUTCOME_HANDOFF, REASON_LANGUAGE_UNRESOLVED, authorized, resolved) if language.nil?

    if resolved.status == Resolver::STATUS_EXACT_CHILD
      evidence_dispatch(authorized, resolved, language)
    else
      range_dispatch(authorized, resolved)
    end
  end

  # Exact family + child → planner → evidence packet. A planner-produced handoff (price unavailable)
  # or clarify (exact-identity revalidation conflict) still carries its packet, with a closed reason.
  def evidence_dispatch(authorized, resolved, language)
    input = @planner.call(product_intent: planner_input(resolved, language),
                          intents: authorized.intents, scenario: authorized.scenario)
    packet = @packet_builder.build(evidence_input: input)
    goals = packet[:response_goals]

    if goals.include?('answer_price')
      terminal(OUTCOME_EVIDENCE_PACKET, REASON_ACCEPTED, authorized, resolved, evidence_packet: packet)
    elsif goals.include?('handoff')
      terminal(OUTCOME_HANDOFF, REASON_PRICE_UNAVAILABLE, authorized, resolved, evidence_packet: packet)
    else
      terminal(OUTCOME_CLARIFY, clarify_reason(goals), authorized, resolved, evidence_packet: packet)
    end
  end

  # Exact family without a child → family price RANGE (internal canonical structure, never customer-facing).
  def range_dispatch(authorized, resolved)
    range = @range_authority.call(family_code: resolved.family_code)
    case range.status
    when Marine::Backend::FamilyPriceRangeAuthority::STATUS_AVAILABLE
      terminal(OUTCOME_FAMILY_PRICE_RANGE, REASON_ACCEPTED, authorized, resolved, price_range: range)
    when Marine::Backend::FamilyPriceRangeAuthority::STATUS_OUTAGE
      terminal(OUTCOME_HANDOFF, REASON_CATALOG_UNAVAILABLE, authorized, resolved)
    else
      terminal(OUTCOME_HANDOFF, REASON_RANGE_UNAVAILABLE, authorized, resolved)
    end
  end

  # A FRESH IntentExtractor-shaped planner input sourced ONLY from the resolver / language resolver.
  # Authoritative identifiers come from the resolver; JEV slot_operations never source them.
  def planner_input(resolved, language)
    {
      product_related: true,
      family_mention: resolved.family_code,
      explicit_child_code: resolved.child_code,
      attribute_candidates: [],
      customer_language: language,
      intent: 'price',
      requested_intents: PRICE_ONLY.dup,
      requires_exact_variant: true,
      quantity_inquiry: false
    }
  end

  def resolve_language(resolved, trigger:, history:, configured_language:)
    @language_resolver.resolve(
      text: trigger,
      provider_language: nil,
      context: history,
      configured_language: configured_language,
      entity_candidates: [resolved.family_code, resolved.child_code].compact,
      trusted_tokens: [resolved.family_code, resolved.family_name].compact
    ).language
  end

  def clarify_reason(goals)
    goals.each { |goal| return CLARIFY_REASON[goal] if CLARIFY_REASON.key?(goal) }
    REASON_VARIANT_AMBIGUOUS
  end

  def adapter_failure(reason, scenario_key)
    outcome, mapped = ADAPTER_FAILURE.fetch(reason, [OUTCOME_STOP, REASON_UNSUPPORTED_PLAN])
    build(outcome_type: outcome, reason: mapped, scenario_key: scenario_key, intents: [], source: SOURCE_NONE)
  end

  def phase_not_executable(authorized)
    build(outcome_type: OUTCOME_LEGACY_PRESERVED, reason: REASON_PHASE_NOT_EXECUTABLE,
          scenario_key: authorized.scenario[:key], intents: authorized.intents, source: SOURCE_NONE)
  end

  def terminal(outcome_type, reason, authorized, resolved, evidence_packet: nil, price_range: nil) # rubocop:disable Metrics/ParameterLists -- flat outcome assembly from already-validated parts
    build(outcome_type: outcome_type, reason: reason, scenario_key: authorized.scenario[:key],
          intents: authorized.intents, source: resolved.source,
          evidence_packet: evidence_packet, price_range: price_range)
  end

  # Build a deep-frozen Result; the scenario key is a frozen copy and the intents array AND every
  # intent String are frozen copies (a frozen array of mutable strings is NOT deep-frozen), while the
  # evidence packet and price range are already deep-frozen by their builders.
  def build(outcome_type:, reason:, scenario_key:, intents:, source:, evidence_packet: nil, price_range: nil) # rubocop:disable Metrics/ParameterLists -- closed Result assembly
    Result.new(
      outcome_type: outcome_type, reason: reason,
      scenario_key: freeze_string(scenario_key),
      intents: Array(intents).map { |intent| freeze_string(intent) }.freeze,
      source: source, evidence_packet: evidence_packet, price_range: price_range
    ).freeze
  end

  def freeze_string(value)
    value.is_a?(String) ? value.dup.freeze : value
  end
end
