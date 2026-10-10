# The closing seam between the already-computed, UNTRUSTED JEV CandidatePlan and the Backend Authority.
# It is reached through AuthorityShadowExecution — both inside the default-OFF Decision shadow AND, since
# Phase 6, as the default authority of the generalized customer execution — and routes EVERY accepted
# single product capability (exact price, family price_range, binary stock, product_listing, and
# product_information) through the SAME ExecutionPolicy authorization + repositories/planner/packet
# builder. It returns a bounded, deep-frozen Result (evidence packet / range / terminal outcome); a
# rejected, unavailable, or non-executable outcome fails closed so the caller runs its unchanged legacy
# path. The price-only language below in the §-notes is historical; the whole-set gate and dispatch now
# cover all five capabilities (see the Phase 3 / Phase 5 notes inline).
#
# Pipeline (all read-only; every step fails closed):
#   1. CandidatePlanToProductIntentAdapter authorizes the plan's schema/scenario/intent via the
#      backend ExecutionPolicy (its Result is NEVER mutated).
#   2. The ExecutionPolicy whole-set gate is enforced: the authorized intent set must be EXACTLY
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
class Marine::Backend::AuthorityCoordinator # rubocop:disable Metrics/ClassLength -- a flat sequence of independent, fail-closed dispatch branches (price + listing)
  Adapter = Marine::Backend::CandidatePlanToProductIntentAdapter
  Resolver = Marine::Backend::CatalogCandidateResolver
  ListingScopeResolver = Marine::Backend::ListingScopeResolver
  ExecutionPolicy = Marine::Backend::ExecutionPolicy

  # The Phase-3 catalog-wide listing intents and the goals their packets carry. A single listing
  # intent routes the dedicated listing path (no price family/variant catalog-identity resolution).
  LISTING_INTENTS = %w[product_overview product_listing product_information].freeze
  LISTING_GOALS = %w[answer_product_overview answer_product_listing answer_product_information].freeze

  OUTCOME_EVIDENCE_PACKET = :evidence_packet
  OUTCOME_FAMILY_PRICE_RANGE = :family_price_range
  OUTCOME_CLARIFY = :clarify
  OUTCOME_HANDOFF = :handoff
  OUTCOME_LEGACY_PRESERVED = :legacy_preserved
  OUTCOME_STOP = :stop

  SOURCE_NONE = :none

  REASON_ACCEPTED = :accepted
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
  REASON_STOCK_UNAVAILABLE = :stock_unavailable
  REASON_INTERNAL_ERROR = :internal_error

  # Phase 5 — the catalog-identity-grounded Evidence intents and the accepted answer goal / unavailable
  # reason each maps to. price_range is family-level (a validated family only); stock requires an exact
  # child/variant. Both route through the SAME resolver + planner + packet builder as exact price, and
  # the planner owns whether the identity is sufficient (a stock turn with only a family clarifies the
  # variant). The exact-price path and the internal exact-family range path are untouched.
  IDENTITY_INTENTS = %w[price_range stock].freeze
  IDENTITY_ANSWER_GOAL = { 'price_range' => 'answer_price_range', 'stock' => 'answer_stock' }.freeze
  IDENTITY_UNAVAILABLE_REASON = { 'price_range' => REASON_RANGE_UNAVAILABLE, 'stock' => REASON_STOCK_UNAVAILABLE }.freeze

  # The proposed-state-transition contract (state_transition_v1). Accepted exact price carries resolver
  # family+variant identity; accepted price_range carries family identity, while an ambiguous price_range
  # family carries a handoff-required nil identity. Other capabilities carry none. The operation is derived
  # from the resolved family vs. the read-only active flow snapshot
  # through the existing ProductStateTransition helper (StateTransitionAdapter maps its operation) — never
  # from the untrusted CandidatePlan or any Model 2 / renderer text.
  PRICE_RANGE_INTENT = 'price_range'.freeze
  STATE_TRANSITION_SCHEMA_VERSION = 'state_transition_v1'.freeze
  STATE_TRANSITION_SOURCE = 'marine_catalog'.freeze
  ProductStateTransition = Marine::Backend::ProductStateTransition
  StateTransitionAdapter = Marine::Backend::StateTransitionAdapter
  FLOW_STATUS_ACTIVE = Marine::Catalog::ProductFlowStateStore::STATUS_ACTIVE

  # Adapter fail-closed reason → coordinator (outcome_type, reason). unresolved_scenario /
  # scenario_mismatch / unsupported_schema / unsupported_intent are terminal stops; a
  # supported-but-non-executable intent set (phase_not_executable) preserves legacy BEFORE any fact
  # repository call. Execution authorization is backend-policy-owned — no capability reasons remain.
  ADAPTER_FAILURE = {
    Adapter::REASON_UNSUPPORTED_SCHEMA => [OUTCOME_STOP, REASON_UNSUPPORTED_PLAN],
    Adapter::REASON_UNRESOLVED_SCENARIO => [OUTCOME_STOP, REASON_SCENARIO_MISMATCH],
    Adapter::REASON_SCENARIO_MISMATCH => [OUTCOME_STOP, REASON_SCENARIO_MISMATCH],
    Adapter::REASON_UNSUPPORTED_INTENT => [OUTCOME_STOP, REASON_UNSUPPORTED_PLAN],
    Adapter::REASON_PHASE_NOT_EXECUTABLE => [OUTCOME_LEGACY_PRESERVED, REASON_PHASE_NOT_EXECUTABLE]
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
                      :evidence_packet, :price_range, :proposed_state_transition, keyword_init: true) do
    def evidence_packet? = !evidence_packet.nil?
    def price_range? = !price_range.nil?
  end

  # A deep-frozen terminal stop Result (no scenario/intents/source), reused by AuthorityShadowExecution
  # for the plan-confidence / scenario-resolution failures it gates BEFORE the coordinator runs.
  def self.stop(reason:)
    Result.new(outcome_type: OUTCOME_STOP, reason: reason, scenario_key: nil,
               intents: [].freeze, source: SOURCE_NONE).freeze
  end

  def initialize(adapter: nil, resolver: nil, listing_scope_resolver: nil, planner: nil, packet_builder: nil, # rubocop:disable Metrics/ParameterLists,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity -- flat injected read-only collaborator defaults
                 range_authority: nil, language_resolver: nil, description_source: nil, catalog_trusted_tokens: nil)
    @adapter = adapter || Adapter.new
    @resolver = resolver || Resolver.new
    @listing_scope_resolver = listing_scope_resolver || ListingScopeResolver.new
    # The product_information RAG description source is threaded into the default planner so a listing
    # fact can be annotated; an explicitly injected planner (tests) keeps its own source.
    @planner = planner || Marine::Backend::ProductExecutionPlanner.new(description_source: description_source)
    @packet_builder = packet_builder || Marine::Backend::EvidencePacketBuilder.new
    @range_authority = range_authority || Marine::Backend::FamilyPriceRangeAuthority.new
    @language_resolver = language_resolver || Marine::Catalog::ConversationLanguageResolver
    # Bug 2 — the shared collaborator that enriches each PRIOR customer history turn with its own
    # bounded Catalog-derived trusted tokens, so a product-name-only prior turn never poisons the
    # strict-sticky delivery language. Uses the read-only ProductFamilyRepository; injectable for tests.
    @catalog_trusted_tokens = catalog_trusted_tokens ||
                              Marine::Catalog::CatalogTrustedTokens.new(family_repository: Marine::Catalog::ProductFamilyRepository.new)
  end

  # phase is part of the ContextBuilder handoff contract (§7.5) and reserved for the planner-input
  # phase semantics; it is carried through for provenance but not consumed in the price-only 2A slice.
  def call(candidate_plan:, scenario_key:, trigger:, history:, phase:, flow_state:, configured_language:, presentation_policy: nil) # rubocop:disable Lint/UnusedMethodArgument,Metrics/ParameterLists -- documented §7.5 closed signature
    authorized = @adapter.call(plan: candidate_plan, scenario_key: scenario_key)
    return adapter_failure(authorized.reason, scenario_key) unless authorized.ok?
    return phase_not_executable(authorized) unless ExecutionPolicy.product_authorized?(authorized.intents)

    # A single listing/information intent is catalog-wide: it needs NO exact price-identity grounding,
    # so it routes the dedicated listing path instead of the CatalogCandidateResolver family/child flow.
    if listing?(authorized.intents)
      return listing_dispatch(authorized, trigger: trigger, history: history, flow_state: flow_state,
                                          configured_language: configured_language)
    end

    # Phase 5 — an explicit single price_range / stock intent is catalog-identity-grounded via the SAME
    # resolver, then routed through the planner + packet builder to an Evidence fact. The presentation
    # policy is threaded ONLY into the price_range answer (v3); stock stays v2. The exact-price path
    # below (and its internal exact-family range branch) is reached only for exactly ["price"].
    if identity?(authorized.intents)
      return identity_dispatch(authorized, identity_intent(authorized.intents),
                               trigger: trigger, history: history, flow_state: flow_state,
                               configured_language: configured_language, presentation_policy: presentation_policy)
    end

    resolved = @resolver.call(trigger: trigger, flow_state: flow_state)
    context = { trigger: trigger, history: history, flow_state: flow_state, configured_language: configured_language }
    dispatch(authorized, resolved, context)
  rescue StandardError
    self.class.stop(reason: REASON_INTERNAL_ERROR)
  end

  private

  # Route an exact catalog identity into the price branch, or fail closed per the resolver status.
  # Every closed resolver status is handled EXPLICITLY; an unknown/malformed status fails closed to
  # stop/internal_error (it must NEVER fall through to the family range).
  def dispatch(authorized, resolved, context)
    case resolved.status
    when Resolver::STATUS_EXACT_FAMILY, Resolver::STATUS_EXACT_CHILD
      with_language(authorized, resolved, context)
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
  def with_language(authorized, resolved, context)
    language = resolve_language(resolved, trigger: context[:trigger], history: context[:history],
                                          configured_language: context[:configured_language])
    return terminal(OUTCOME_HANDOFF, REASON_LANGUAGE_UNRESOLVED, authorized, resolved) if language.nil?

    if resolved.status == Resolver::STATUS_EXACT_CHILD
      evidence_dispatch(authorized, resolved, language, context[:flow_state])
    else
      range_dispatch(authorized, resolved)
    end
  end

  # Exact family + child → planner → evidence packet. A planner-produced handoff (price unavailable)
  # or clarify (exact-identity revalidation conflict) still carries its packet, with a closed reason.
  def evidence_dispatch(authorized, resolved, language, flow_state)
    input = @planner.call(product_intent: planner_input(resolved, language),
                          intents: authorized.intents, scenario: authorized.scenario)
    packet = @packet_builder.build(evidence_input: input)
    goals = packet[:response_goals]

    if goals.include?('answer_price')
      transition = exact_price_transition(resolved, flow_state)
      terminal(OUTCOME_EVIDENCE_PACKET, REASON_ACCEPTED, authorized, resolved,
               evidence_packet: packet, proposed_state_transition: transition)
    elsif goals.include?('handoff')
      terminal(OUTCOME_HANDOFF, REASON_PRICE_UNAVAILABLE, authorized, resolved, evidence_packet: packet)
    else
      terminal(OUTCOME_CLARIFY, clarify_reason(goals), authorized, resolved, evidence_packet: packet)
    end
  end

  def listing?(intents)
    intents.length == 1 && LISTING_INTENTS.include?(intents.first)
  end

  def identity?(intents)
    intents.length == 1 && IDENTITY_INTENTS.include?(intents.first)
  end

  def identity_intent(intents)
    intents.first
  end

  # The Phase-5 catalog-identity Evidence path (price_range / stock): resolve the exact catalog
  # identity via the SAME resolver as exact price, fix the delivery language, then let the planner read
  # the authoritative range / binary stock and build the packet. An unavailable/ambiguous/no-match
  # resolver status fails closed exactly as the price path does; an unknown status can never fall
  # through to a fact.
  def identity_dispatch(authorized, intent, trigger:, history:, flow_state:, configured_language:, presentation_policy: nil) # rubocop:disable Metrics/ParameterLists -- the closed §7.5 resolver inputs threaded verbatim
    resolved = @resolver.call(trigger: trigger, flow_state: flow_state)
    case resolved.status
    when Resolver::STATUS_EXACT_FAMILY, Resolver::STATUS_EXACT_CHILD
      identity_evidence(authorized, intent, resolved, trigger: trigger, history: history, flow_state: flow_state,
                                                      configured_language: configured_language, presentation_policy: presentation_policy)
    when Resolver::STATUS_UNAVAILABLE
      terminal(OUTCOME_HANDOFF, REASON_CATALOG_UNAVAILABLE, authorized, resolved)
    when Resolver::STATUS_AMBIGUOUS
      # A price_range ambiguity carries the SAME closed envelope with handoff_required:true / nil identity
      # (no family is fabricated from the ambiguous matches); the stock ambiguity keeps its plain clarify.
      terminal(OUTCOME_CLARIFY, resolved.reason, authorized, resolved,
               proposed_state_transition: (intent == PRICE_RANGE_INTENT ? ambiguity_transition(flow_state) : nil))
    when Resolver::STATUS_NO_CATALOG_MATCH
      terminal(OUTCOME_LEGACY_PRESERVED, REASON_CANDIDATE_CONTEXT_INSUFFICIENT, authorized, resolved)
    else
      self.class.stop(reason: REASON_INTERNAL_ERROR)
    end
  end

  # Resolve the delivery language BEFORE the planner (nil fails closed factless), build the packet, and
  # classify its goals: the intent's answer goal is accepted; a planner handoff (range/stock
  # unavailable, or an insufficient identity) is a closed handoff; anything else is a clarify.
  def identity_evidence(authorized, intent, resolved, trigger:, history:, flow_state:, configured_language:, presentation_policy: nil) # rubocop:disable Metrics/ParameterLists -- closed resolver inputs threaded verbatim
    language = resolve_language(resolved, trigger: trigger, history: history, configured_language: configured_language)
    return terminal(OUTCOME_HANDOFF, REASON_LANGUAGE_UNRESOLVED, authorized, resolved) if language.nil?

    packet = @packet_builder.build(evidence_input: @planner.call(
      product_intent: identity_planner_input(resolved, language, intent), intents: authorized.intents,
      scenario: authorized.scenario, presentation_policy: (intent == PRICE_RANGE_INTENT ? presentation_policy : nil)
    ))
    classify_identity_packet(packet, authorized, resolved, intent, flow_state)
  end

  def classify_identity_packet(packet, authorized, resolved, intent, flow_state)
    goals = packet[:response_goals]
    if goals.include?(IDENTITY_ANSWER_GOAL[intent])
      # In this price_range/stock branch, only accepted price_range carries a family transition;
      # accepted exact price is handled separately by #evidence_dispatch with family+variant identity.
      transition = intent == PRICE_RANGE_INTENT ? price_range_transition(resolved, flow_state) : nil
      terminal(OUTCOME_EVIDENCE_PACKET, REASON_ACCEPTED, authorized, resolved, evidence_packet: packet, proposed_state_transition: transition)
    elsif goals.include?('handoff')
      terminal(OUTCOME_HANDOFF, IDENTITY_UNAVAILABLE_REASON[intent], authorized, resolved, evidence_packet: packet)
    else
      terminal(OUTCOME_CLARIFY, clarify_reason(goals), authorized, resolved, evidence_packet: packet)
    end
  end

  # Accepted exact price establishes the resolver's Catalog-derived family+variant identity. The
  # operation is :update only for the same active family; fresh, expired, and switched-family flows
  # start clean. Blank/malformed identity fails closed to nil, which the customer consumer rejects.
  def exact_price_transition(resolved, flow_state)
    operation = price_range_operation(resolved, flow_state)
    family = resolved.family_code.to_s.strip
    variant = resolved.child_code.to_s.strip
    return nil if operation.nil? || family.empty? || variant.empty?

    deep_freeze(
      schema_version: STATE_TRANSITION_SCHEMA_VERSION,
      operation: operation,
      capability: 'price',
      handoff_required: false,
      authoritative_identity: {
        family_code: family.dup,
        variant_code: variant.dup,
        source: STATE_TRANSITION_SOURCE
      }
    )
  end

  # The closed, deep-frozen non-handoff price_range transition: operation derived from the resolved
  # family vs. the read-only active flow via ProductStateTransition + StateTransitionAdapter, identity
  # taken ONLY from the resolver family. A derivation failure (e.g. a blank family) fails closed to nil
  # so a range reply without a persistable identity simply carries no transition.
  def price_range_transition(resolved, flow_state)
    operation = price_range_operation(resolved, flow_state)
    return nil if operation.nil?

    deep_freeze(
      schema_version: STATE_TRANSITION_SCHEMA_VERSION,
      operation: operation,
      capability: PRICE_RANGE_INTENT,
      handoff_required: false,
      authoritative_identity: { family_code: resolved.family_code.to_s.dup, source: STATE_TRANSITION_SOURCE }
    )
  end

  # The SAME closed envelope for a price_range catalog ambiguity: no family is fabricated (identity nil),
  # handoff_required is true, and the operation is a nominal :start that is NEVER applied (the consumer
  # hands off and writes nothing). Kept deterministic and closed only to satisfy the fixed envelope shape.
  def ambiguity_transition(_flow_state)
    deep_freeze(
      schema_version: STATE_TRANSITION_SCHEMA_VERSION,
      operation: :start,
      capability: PRICE_RANGE_INTENT,
      handoff_required: true,
      authoritative_identity: nil
    )
  end

  # Derive :start / :update from the authoritative resolver family vs. the read-only active flow snapshot
  # (never Model 1 / plan text): the same active family is a variant_replacement (:update); a fresh,
  # switched, or expired flow is a product_replacement (:start), which clears stale variant/catalog state.
  # Routed through the existing ProductStateTransition helper so the operation enum can never drift.
  def price_range_operation(resolved, flow_state)
    family_transition_operation(resolved.family_code, flow_state)
  end

  def family_transition_operation(family_code, flow_state)
    kind = if same_active_family?(flow_state, family_code)
             ProductStateTransition::VARIANT_REPLACEMENT
           else
             ProductStateTransition::PRODUCT_REPLACEMENT
           end
    transition = ProductStateTransition.new.call(existing: flow_state, kind: kind, set: { 'validated_family' => family_code })
    StateTransitionAdapter.new.call(transition)
  rescue StandardError
    nil
  end

  def same_active_family?(flow_state, family_code)
    return false unless flow_state.is_a?(Hash)

    flow = flow_state.transform_keys(&:to_s)
    family = family_code.to_s.strip
    flow['status'] == FLOW_STATUS_ACTIVE && !family.empty? && flow['validated_family'].to_s.strip == family
  end

  # A FRESH planner input for a price_range / stock turn, sourced ONLY from the resolver / language
  # resolver. The authoritative identifiers come from the resolver; the untrusted plan slot_operations
  # never source them. Only stock needs an exact variant; price_range is family-level.
  def identity_planner_input(resolved, language, intent)
    {
      product_related: true,
      family_mention: resolved.family_code,
      explicit_child_code: resolved.child_code,
      attribute_candidates: [],
      customer_language: language,
      intent: intent,
      requested_intents: [intent],
      requires_exact_variant: intent == 'stock',
      quantity_inquiry: false
    }
  end

  # The catalog-wide listing/information path: resolve the delivery language, then let the planner read
  # the bounded top-level catalog page (exact-resolving the plan's untrusted product candidate against
  # the catalog authority when present). An accepted listing packet is terminal; a planner handoff
  # (empty catalog / outage / unresolved candidate) is a closed handoff. No resolver identity is used,
  # so the Result carries SOURCE_NONE.
  def listing_dispatch(authorized, trigger:, history:, flow_state:, configured_language:)
    language = resolve_listing_language(authorized, trigger: trigger, history: history, configured_language: configured_language)
    return listing_terminal(OUTCOME_HANDOFF, REASON_LANGUAGE_UNRESOLVED, authorized) if language.nil?

    scope = listing_scope(authorized, trigger)
    return listing_terminal(OUTCOME_HANDOFF, REASON_CATALOG_UNAVAILABLE, authorized) if scope == :handoff

    packet = @packet_builder.build(evidence_input: @planner.call(
      product_intent: listing_planner_input(authorized, language, scope),
      intents: authorized.intents, scenario: authorized.scenario
    ))
    if packet[:response_goals].intersect?(LISTING_GOALS)
      transition = listing_transition(packet, flow_state)
      listing_terminal(OUTCOME_EVIDENCE_PACKET, REASON_ACCEPTED, authorized, evidence_packet: packet,
                                                                             proposed_state_transition: transition)
    else
      listing_terminal(OUTCOME_HANDOFF, REASON_CATALOG_UNAVAILABLE, authorized, evidence_packet: packet)
    end
  rescue StandardError
    listing_terminal(OUTCOME_HANDOFF, REASON_CATALOG_UNAVAILABLE, authorized)
  end

  def listing_scope(authorized, trigger)
    return nil if authorized.intents == ['product_overview']

    resolved = @listing_scope_resolver.call(trigger: trigger)
    case resolved.status
    when ListingScopeResolver::STATUS_BROAD then nil
    when ListingScopeResolver::STATUS_PRODUCT then { product: resolved.product }
    when ListingScopeResolver::STATUS_ITEM_GROUP then { item_group: resolved.item_group }
    else :handoff
    end
  end

  # Product identity and Item Group scope are distinct planner fields. Only the bounded Backend resolver
  # may populate item_group_scope; it never enters product/variant slots or family-context state.
  def listing_planner_input(authorized, language, scope)
    {
      product_related: true,
      family_mention: scope&.dig(:product, :code),
      item_group_scope: scope&.dig(:item_group),
      explicit_child_code: nil,
      attribute_candidates: [],
      customer_language: language,
      intent: authorized.intents.first,
      requested_intents: [],
      requires_exact_variant: false,
      quantity_inquiry: false
    }
  end

  # Delivery language for a listing turn, fixed BEFORE the planner. A nil language fails closed to a
  # handoff (no silent default). The untrusted candidate only anchors language detection — never a
  # trusted token, since it is not catalog-validated at this point.
  def resolve_listing_language(authorized, trigger:, history:, configured_language:)
    mention = authorized.product_intent[:family_mention]
    @language_resolver.resolve(
      text: trigger, provider_language: nil, context: enriched_history(history),
      configured_language: configured_language,
      entity_candidates: [mention].compact, trusted_tokens: []
    ).language
  end

  def listing_terminal(outcome_type, reason, authorized, evidence_packet: nil, proposed_state_transition: nil)
    build(outcome_type: outcome_type, reason: reason, scenario_key: authorized.scenario[:key],
          intents: authorized.intents, source: SOURCE_NONE, evidence_packet: evidence_packet,
          proposed_state_transition: proposed_state_transition)
  end

  # A narrowed listing/information answer establishes family context only when the accepted Evidence
  # packet carries one repository-validated product slot bound to the same sole catalog-listed code.
  # Broad pages and malformed/mismatched packets remain state no-ops.
  def listing_transition(packet, flow_state)
    family = packet.dig(:validated_slots, :product, :code).to_s.strip
    products = packet.dig(:facts, :product_listing, :products)
    return nil if family.empty? || !products.is_a?(Array) || products.length != 1 || products.first[:code] != family

    family_context_transition(family, flow_state)
  end

  def family_context_transition(family, flow_state)
    operation = family_transition_operation(family, flow_state)
    return nil if operation.nil?

    deep_freeze(
      schema_version: STATE_TRANSITION_SCHEMA_VERSION,
      operation: operation,
      capability: 'family_context',
      handoff_required: false,
      authoritative_identity: { family_code: family.dup, source: STATE_TRANSITION_SOURCE }
    )
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
      requested_intents: ExecutionPolicy::EXECUTABLE_INTENTS.dup,
      requires_exact_variant: true,
      quantity_inquiry: false
    }
  end

  def resolve_language(resolved, trigger:, history:, configured_language:)
    @language_resolver.resolve(
      text: trigger,
      provider_language: nil,
      context: enriched_history(history),
      configured_language: configured_language,
      entity_candidates: [resolved.family_code, resolved.child_code].compact,
      trusted_tokens: [resolved.family_code, resolved.family_name].compact
    ).language
  end

  # Bug 2 — rebuild the bounded prior history into FRESH entries whose each CUSTOMER turn carries its
  # own Catalog-derived trusted tokens (any incoming trusted_tokens discarded). This closes the
  # prior-history asymmetry for the listing and validated-family exact/range language seams alike; the
  # current-turn authority/selection behavior is untouched (only the resolver's context changes).
  def enriched_history(history)
    @catalog_trusted_tokens.enrich_context(history)
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

  def terminal(outcome_type, reason, authorized, resolved, evidence_packet: nil, price_range: nil, proposed_state_transition: nil) # rubocop:disable Metrics/ParameterLists -- flat outcome assembly from already-validated parts
    build(outcome_type: outcome_type, reason: reason, scenario_key: authorized.scenario[:key],
          intents: authorized.intents, source: resolved.source,
          evidence_packet: evidence_packet, price_range: price_range, proposed_state_transition: proposed_state_transition)
  end

  # Build a deep-frozen Result; the scenario key is a frozen copy and the intents array AND every
  # intent String are frozen copies (a frozen array of mutable strings is NOT deep-frozen), while the
  # evidence packet, price range, and proposed state transition are already deep-frozen by their builders.
  def build(outcome_type:, reason:, scenario_key:, intents:, source:, evidence_packet: nil, price_range: nil, proposed_state_transition: nil) # rubocop:disable Metrics/ParameterLists -- closed Result assembly
    Result.new(
      outcome_type: outcome_type, reason: reason,
      scenario_key: freeze_string(scenario_key),
      intents: Array(intents).map { |intent| freeze_string(intent) }.freeze,
      source: source, evidence_packet: evidence_packet, price_range: price_range,
      proposed_state_transition: proposed_state_transition
    ).freeze
  end

  def freeze_string(value)
    value.is_a?(String) ? value.dup.freeze : value
  end

  # Recursively freeze a closed transition graph (Hash keys, values, and nested Hashes) so the envelope
  # is DEEPLY frozen — a frozen outer Hash holding a mutable identity Hash would fail the consumer gate.
  def deep_freeze(value)
    case value
    when Hash then value.each { |key, child| deep_freeze(key) && deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end
end
