# Fase 3A-1 (isolated / mock-only) — backend repository validation & execution plan.
#
# Turns an adapter-produced, still-UNTRUSTED product-intent input into a bounded EVIDENCE
# INPUT the EvidencePacketBuilder serializes. It is the ONLY authority over facts: it
# revalidates every candidate against the injected read-only repositories and NEVER trusts a
# slot value from the plan. It performs NO provider call, NO state write, and has ZERO runtime
# wiring; repositories are injected so tests run fully mocked with no catalog DB.
#
# Authority rules:
#   * Family: exact resolution via ProductFamilyRepository#resolve_exact (exact code or exact
#     name). No match -> clarify_product; never a guessed family.
#   * Variant: exact child-code only via VariantResolver (row-derived exact child code; NO
#     attribute candidates are passed in 3A-1). :missing -> clarify_variant; :ambiguous ->
#     clarify_ambiguous_variant. A natural color/alias/attribute is never guessed.
#   * Price: PriceRepository tuple + PriceDisplayFormatter envelope (canonical + immutable
#     display). Unavailable/conflict/format failure -> NO price fact + handoff.
#   * Stock: StockRepository BINARY availability only (available/unavailable). Outage/error
#     (CatalogUnavailableError) -> NO stock fact + handoff; never a quantity, warehouse, or
#     `unknown` status.
#
# Phase 1 (Opsi B): execution authorization is backend-policy-owned (Marine::Backend::ExecutionPolicy)
# and the executable set is exactly ["price"]. Scenario carries provenance only ({ key: }); the planner
# never reads a per-scenario capability list.
class Marine::Backend::ProductExecutionPlanner
  ExecutionPolicy = Marine::Backend::ExecutionPolicy

  # The frozen product goal each supported intent maps to, within the A8-01 closed enum. price
  # and stock get their own answer goals; the informational/identity intents share
  # answer_product_overview (the packet has no distinct catalog/parent/variant answer goal in 3A).
  RESPONSE_GOAL_FOR_INTENT = {
    'price' => 'answer_price',
    'stock' => 'answer_stock',
    'product_overview' => 'answer_product_overview',
    'catalog' => 'answer_product_overview',
    'parent_info' => 'answer_product_overview',
    'variant_info' => 'answer_product_overview'
  }.freeze

  # The only intents this planner may execute (transactional + informational product_overview) —
  # exactly the keys it can map to a response goal. Defense in depth: the planner rejects anything
  # outside this set itself rather than trusting the adapter to have filtered it.
  SUPPORTED_INTENTS = RESPONSE_GOAL_FOR_INTENT.keys.freeze

  # Intents that require a validated family / a validated variant before any fact/answer.
  FAMILY_NEEDED = %w[price stock parent_info variant_info catalog].freeze
  VARIANT_NEEDED = %w[price stock variant_info].freeze

  # Binary StockRepository status -> the A8-01 packet stock enum. An unexpected status never
  # reaches here (the repository fails closed with CatalogUnavailableError instead).
  STOCK_STATUS = { available: 'available', empty: 'unavailable' }.freeze

  def initialize(family_repository: nil, variant_resolver: nil, price_repository: nil, # rubocop:disable Metrics/ParameterLists -- injected read-only repository dependencies (all optional)
                 stock_repository: nil, price_formatter: nil, clock: nil)
    @family_repository = family_repository || Marine::Catalog::ProductFamilyRepository.new
    @variant_resolver = variant_resolver || Marine::Catalog::VariantResolver.new
    @price_repository = price_repository || Marine::Catalog::PriceRepository.new
    @stock_repository = stock_repository || Marine::Catalog::StockRepository.new
    @price_formatter = price_formatter || Marine::Catalog::PriceDisplayFormatter.new
    @clock = clock || -> { Time.current }
  end

  # product_intent: the adapter's backend-owned product-intent input (IntentExtractor-shaped).
  # intents:        the validated executable candidate intents (ExecutionPolicy-authorized; Phase 1 price).
  # scenario:       { key: } provenance from the adapter.
  def call(product_intent:, intents:, scenario:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent fail-closed guards
    # Defense in depth: a non-Hash product_intent (a direct programmer call) fails closed to a
    # factless handoff rather than raising an unbounded error dereferencing it.
    return handoff(Context.new(scenario, intents, nil)) unless product_intent.is_a?(Hash)

    context = Context.new(scenario, intents, product_intent[:customer_language])
    # Defense in depth: never trust that only the adapter reached here. An empty, unsupported, or
    # non-ExecutionPolicy-authorized intent set fails closed to a factless handoff rather than executing.
    return handoff(context) unless executable?(intents)

    family = resolve_family(product_intent[:family_mention])
    return handoff(context) if family == :unavailable
    return clarify(context, 'clarify_product', %w[product], {}) if intents.intersect?(FAMILY_NEEDED) && family.nil?

    variant = resolve_variant(family, product_intent, intents)
    return handoff(context) if variant == :unavailable
    return clarify(context, variant[:clarify_goal], %w[variant_input], validated_slots(family, nil)) if variant.is_a?(Hash) && variant[:clarify_goal]

    build_answer(context, family, variant)
  end

  private

  # The per-request presentation constants (scenario + candidate intents + customer language) that
  # ride into every evidence input, so the helpers avoid long parameter lists.
  Context = Struct.new(:scenario, :intents, :language)

  # A plan is executable only when the intents are the exact ExecutionPolicy-authorized executable set
  # (Phase 1: exactly ["price"]) AND a subset of the supported product intents. Anything else — empty,
  # non-price, mixed, duplicated, or out-of-support — fails closed BEFORE any repository read.
  def executable?(intents)
    return false unless intents.is_a?(Array) && !intents.empty?

    (intents - SUPPORTED_INTENTS).empty? && ExecutionPolicy.authorized?(intents)
  end

  attr_reader :family_repository, :variant_resolver, :price_repository, :stock_repository, :price_formatter

  # { code:, name: } | nil (blank mention or no exact match) | :unavailable (catalog outage).
  # A blank mention never touches the repository.
  def resolve_family(family_mention)
    return nil if family_mention.to_s.strip.empty?

    family_repository.resolve_exact(family_mention)
  rescue Marine::Catalog::Errors::CatalogUnavailableError
    :unavailable
  end

  # One of: { status: :resolved, code: } (validated variant), { clarify_goal: <goal> }
  # (missing/ambiguous), nil (no variant needed), or :unavailable (catalog outage).
  #
  # EXACT-code-only variant authority (3A-1): the resolver is given ONLY the exact explicit child
  # code — NO attribute candidates are ever passed. A natural/display/attribute candidate therefore
  # never resolves a code; the resolver returns :missing and this turn clarifies the variant.
  def resolve_variant(family, product_intent, intents)
    return nil unless family && intents.intersect?(VARIANT_NEEDED)

    result = variant_resolver.resolve(
      family_code: family[:code],
      explicit_child_code: product_intent[:explicit_child_code],
      attribute_candidates: []
    )
    return result if result[:status] == :resolved

    { clarify_goal: result[:reason] == :ambiguous ? 'clarify_ambiguous_variant' : 'clarify_variant' }
  rescue Marine::Catalog::Errors::CatalogUnavailableError
    :unavailable
  end

  def build_answer(context, family, variant)
    variant_code = variant.is_a?(Hash) ? variant[:code] : nil
    facts = {}
    goals = context.intents.map { |intent| resolve_intent(intent, family, variant_code, context.language, facts) }
    evidence_input(context, goals: goals.compact.uniq, slots: validated_slots(family, variant), facts: facts)
  end

  # The response goal for one intent. A fact-bearing intent (price/stock) stores its verified fact
  # and returns its answer goal, or 'handoff' when the repository yields no fact (fail-closed
  # omission). product_overview needs a validated family to answer — with no family evidence it
  # hands off rather than emitting answer_product_overview over an empty slot/fact packet that
  # Model 2 could hallucinate from. catalog/parent_info/variant_info already required a family
  # (FAMILY_NEEDED clarifies before here), so they map straight to their answer goal.
  def resolve_intent(intent, family, variant_code, language, facts)
    case intent
    when 'price' then store_fact(facts, :price, price_fact(variant_code, language), 'answer_price')
    when 'stock' then store_fact(facts, :stock, stock_fact(variant_code), 'answer_stock')
    when 'product_overview' then family ? 'answer_product_overview' : 'handoff'
    else RESPONSE_GOAL_FOR_INTENT[intent]
    end
  end

  def store_fact(facts, key, fact, goal)
    return 'handoff' if fact.nil?

    facts[key] = fact
    goal
  end

  # Exact price envelope, or nil (unavailable / conflict / unsupported locale / catalog outage).
  def price_fact(variant_code, language)
    return nil if variant_code.nil?

    price = price_repository.price_for(variant_code)
    return nil unless price[:status] == :available

    result = price_formatter.format(descriptor: price_descriptor(variant_code, price), locale: language.to_s)
    return nil unless result.ok?

    price_envelope(result.envelope)
  rescue Marine::Catalog::Errors::CatalogUnavailableError
    nil
  end

  def price_descriptor(variant_code, price)
    { kind: :price_available, variant_code: variant_code,
      price_list_rate: price[:price_list_rate], currency: price[:currency], uom: price[:uom] }
  end

  def price_envelope(env)
    {
      canonical: {
        variant_code: env[:canonical][:variant_code], currency: env[:canonical][:currency],
        price_list_rate: env[:canonical][:price_list_rate], uom: env[:canonical][:uom]
      },
      display: {
        product: env[:display][:product], currency: env[:display][:currency],
        amount: env[:display][:amount], uom: env[:display][:uom]
      },
      policy_version: env[:policy_version],
      source: 'catalog_price_repository',
      checked_at: now_iso8601
    }
  end

  # Binary availability fact, or nil on outage/error/indeterminate (never a `unknown` status).
  def stock_fact(variant_code)
    return nil if variant_code.nil?

    mapped = STOCK_STATUS[stock_repository.status_for(variant_code)]
    return nil if mapped.nil?

    { status: mapped, source: 'stock_repository', checked_at: now_iso8601 }
  rescue Marine::Catalog::Errors::CatalogUnavailableError
    nil
  end

  def validated_slots(family, variant)
    slots = {}
    slots[:product] = { code: family[:code], name: family[:name], source: 'marine_catalog' } if family
    if variant.is_a?(Hash) && variant[:status] == :resolved
      slots[:variant] = { code: variant[:code], display_name: nil, attributes: {},
                          resolution_status: 'resolved', source: 'marine_catalog' }
    end
    slots
  end

  def handoff(context)
    evidence_input(context, goals: %w[handoff])
  end

  def clarify(context, goal, missing, slots)
    evidence_input(context, goals: [goal], missing: missing, slots: slots)
  end

  # variant_candidates is always empty here: the VariantResolver surfaces resolved/missing/ambiguous
  # but never a candidate list in 3A-1, so the packet's variant_candidates bound is exercised by the
  # builder directly rather than fed from this planner.
  def evidence_input(context, goals:, slots: {}, facts: {}, missing: [])
    deep_freeze(
      scenario: context.scenario,
      intents: context.intents,
      customer_language: context.language,
      response_goals: goals,
      validated_slots: slots,
      facts: facts,
      missing_slots: missing,
      variant_candidates: []
    )
  end

  def now_iso8601 = @clock.call.utc.iso8601

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end
end
