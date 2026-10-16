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
class Marine::Backend::ProductExecutionPlanner # rubocop:disable Metrics/ClassLength -- a flat sequence of independent per-intent fail-closed planners
  ExecutionPolicy = Marine::Backend::ExecutionPolicy

  # The frozen product goal each supported intent maps to, within the A8-01 closed enum. price
  # and stock get their own answer goals; the informational/identity intents share
  # answer_product_overview (the packet has no distinct catalog/parent/variant answer goal in 3A).
  RESPONSE_GOAL_FOR_INTENT = {
    'price' => 'answer_price',
    'price_range' => 'answer_price_range',
    'stock' => 'answer_stock',
    'product_overview' => 'answer_product_overview',
    'catalog' => 'answer_product_overview',
    'parent_info' => 'answer_product_overview',
    'variant_info' => 'answer_product_overview',
    'product_listing' => 'answer_product_listing',
    'product_information' => 'answer_product_information'
  }.freeze

  # The Phase-3 catalog-wide listing intents. They need NO family/variant: the answer is a bounded
  # page of active top-level products (product_listing = names only; product_information = the same
  # bounded set, with RAG descriptions attached ONLY to those authorized entries).
  LISTING_INTENTS = %w[product_listing product_information].freeze
  OFFERING_INTENT = 'product_overview'.freeze

  # The only intents this planner may execute (transactional + informational product_overview) —
  # exactly the keys it can map to a response goal. Defense in depth: the planner rejects anything
  # outside this set itself rather than trusting the adapter to have filtered it.
  SUPPORTED_INTENTS = RESPONSE_GOAL_FOR_INTENT.keys.freeze

  # Intents that require a validated family / a validated variant before any fact/answer. price_range
  # needs a validated FAMILY only (the range spans every active child), never a single variant.
  FAMILY_NEEDED = %w[price price_range stock parent_info variant_info catalog].freeze
  VARIANT_NEEDED = %w[price stock variant_info].freeze

  # Binary StockRepository status -> the A8-01 packet stock enum. An unexpected status never
  # reaches here (the repository fails closed with CatalogUnavailableError instead).
  STOCK_STATUS = { available: 'available', empty: 'unavailable' }.freeze

  def initialize(family_repository: nil, variant_resolver: nil, price_repository: nil, # rubocop:disable Metrics/ParameterLists,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity -- injected read-only repository dependencies (all optional)
                 stock_repository: nil, price_formatter: nil, listing_repository: nil,
                 range_authority: nil, description_source: nil, clock: nil)
    @family_repository = family_repository || Marine::Catalog::ProductFamilyRepository.new
    @variant_resolver = variant_resolver || Marine::Catalog::VariantResolver.new
    @price_repository = price_repository || Marine::Catalog::PriceRepository.new
    @stock_repository = stock_repository || Marine::Catalog::StockRepository.new
    @price_formatter = price_formatter || Marine::Catalog::PriceDisplayFormatter.new
    @listing_repository = listing_repository || Marine::Catalog::ProductListingRepository.new
    # The Phase-5 family-level price RANGE authority (reuses the exact-price qualifying policy across
    # every active child). Injected for isolated tests; it owns no customer text.
    @range_authority = range_authority || Marine::Backend::FamilyPriceRangeAuthority.new
    # RAG description source for product_information: a callable products -> { code => description }
    # over the ALREADY catalog-authorized page (one bounded approved query; never per-code). It may
    # ONLY annotate a listed code; it can never add, rename, or invent a product. Defaults to a null
    # source (no descriptions wired), so an absent description stays absent.
    @description_source = description_source || ->(_products) { {} }
    @clock = clock || -> { Time.current }
  end

  # product_intent:      the adapter's backend-owned product-intent input (IntentExtractor-shaped).
  # intents:             the validated executable candidate intents (ExecutionPolicy-authorized; Phase 1 price).
  # scenario:            { key: } provenance from the adapter.
  # presentation_policy: OPTIONAL plain closed policy data threaded from the customer composition root.
  #                      It is embedded in the evidence input ONLY for an answer_price_range answer (v3);
  #                      every other goal ignores it, so those packets stay v2.
  def call(product_intent:, intents:, scenario:, presentation_policy: nil) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- flat sequence of independent fail-closed guards
    # Defense in depth: a non-Hash product_intent (a direct programmer call) fails closed to a
    # factless handoff rather than raising an unbounded error dereferencing it.
    return handoff(Context.new(scenario, intents, nil)) unless product_intent.is_a?(Hash)

    context = Context.new(scenario, intents, product_intent[:customer_language])
    # Defense in depth: never trust that only the adapter reached here. An empty, unsupported, or
    # non-ExecutionPolicy-authorized intent set fails closed to a factless handoff rather than executing.
    return handoff(context) unless executable?(intents)

    # Company-wide offerings are authoritative item groups, never an item-row dump. Category/product
    # listings use a separate bounded top-level item path.
    return offering_answer(context) if intents == [OFFERING_INTENT]
    return listing_answer(context, product_intent) if listing_only?(intents)

    family = resolve_family(product_intent[:family_mention])
    return handoff(context) if family == :unavailable
    return clarify(context, 'clarify_product', %w[product], {}) if intents.intersect?(FAMILY_NEEDED) && family.nil?

    variant = resolve_variant(family, product_intent, intents)
    return handoff(context) if variant == :unavailable
    return clarify(context, variant[:clarify_goal], %w[variant_input], validated_slots(family, nil)) if variant.is_a?(Hash) && variant[:clarify_goal]

    build_answer(context, family, variant, presentation_policy)
  end

  private

  # The per-request presentation constants (scenario + candidate intents + customer language) that
  # ride into every evidence input, so the helpers avoid long parameter lists.
  Context = Struct.new(:scenario, :intents, :language)

  # A plan is executable only when the intents are exactly ONE ExecutionPolicy-authorized product
  # intent (["price"], ["product_listing"], or ["product_information"]) AND a subset of the supported
  # product intents. Anything else — empty, unactivated (stock/catalog/...), mixed, duplicated, or
  # out-of-support — fails closed BEFORE any repository read.
  def executable?(intents)
    return false unless intents.is_a?(Array) && !intents.empty?

    (intents - SUPPORTED_INTENTS).empty? && ExecutionPolicy.product_authorized?(intents)
  end

  attr_reader :family_repository, :variant_resolver, :price_repository, :stock_repository,
              :price_formatter, :listing_repository, :description_source, :range_authority

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

  def build_answer(context, family, variant, presentation_policy = nil)
    variant_code = variant.is_a?(Hash) ? variant[:code] : nil
    facts = {}
    goals = context.intents.filter_map { |intent| resolve_intent(intent, family, variant_code, context.language, facts) }.uniq
    evidence_input(context, goals: goals, slots: validated_slots(family, variant), facts: facts,
                            presentation_policy: policy_for(goals, presentation_policy))
  end

  # The presentation policy is carried into the evidence input ONLY for a pure answer_price_range answer
  # (the single v3 goal in this checkpoint). Every other goal drops it, so its packet stays v2.
  def policy_for(goals, presentation_policy)
    presentation_policy if presentation_policy && goals == %w[answer_price_range]
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
    when 'price_range' then store_fact(facts, :price_range, price_range_fact(family, language), 'answer_price_range')
    when 'stock' then store_fact(facts, :stock, stock_fact(variant_code), 'answer_stock')
    when 'product_overview' then family ? 'answer_product_overview' : 'handoff'
    else RESPONSE_GOAL_FOR_INTENT[intent]
    end
  end

  def listing_only?(intents)
    intents.length == 1 && LISTING_INTENTS.include?(intents.first)
  end

  # The listing/info answer. A bounded top-level page by default; when Model 1 supplied a product
  # candidate it is exact-resolved against the active top-level Catalog authority and the page is
  # restricted to that one product. A supplied-but-unresolved candidate (:unknown) or a catalog
  # outage (:unavailable) fails closed to a factless handoff — an unknown product is NEVER shown as
  # available. product_information attaches approved RAG descriptions to the authorized entries only.
  def offering_answer(context)
    page = listing_repository.active_item_groups
    groups = page[:item_groups]
    return handoff(context) unless groups.is_a?(Array) && groups.any?
    return handoff(context) unless page[:returned_count] == groups.length

    fact = {
      item_groups: groups,
      returned_count: groups.length,
      total_count: page[:total_count],
      complete: page[:has_more] == false,
      source: 'catalog_item_group_repository',
      checked_at: now_iso8601
    }
    evidence_input(context, goals: %w[answer_product_overview], slots: {}, facts: { company_offerings: fact })
  rescue Marine::Catalog::Errors::CatalogUnavailableError
    handoff(context)
  end

  def listing_answer(context, product_intent)
    descriptions = context.intents.first == 'product_information'
    scope = resolve_listing_scope(product_intent)
    return handoff(context) if %i[unavailable unknown].include?(scope)

    fact = listing_fact(descriptions: descriptions, product: scope&.dig(:product), item_group: scope&.dig(:item_group))
    return handoff(context) if fact.nil?

    goal = descriptions ? 'answer_product_information' : 'answer_product_listing'
    evidence_input(context, goals: [goal], slots: validated_slots(scope&.dig(:product), nil),
                            facts: { product_listing: fact })
  end

  # The coordinator transports independently resolved authority identities: family_mention is product
  # identity only; item_group_scope is category identity only. A direct caller supplying both fails closed.
  def resolve_listing_scope(product_intent) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity -- two independent authority namespaces with explicit collision/outage gates
    mention = product_intent[:family_mention].to_s.strip.presence
    group_scope = product_intent[:item_group_scope].to_s.strip.presence
    return :unknown if mention && group_scope
    return nil unless mention || group_scope

    if mention
      product = listing_repository.exact_top_level(mention)
      product ? { product: product } : :unknown
    else
      item_group = listing_repository.exact_item_group(group_scope)
      item_group ? { item_group: item_group } : :unknown
    end
  rescue Marine::Catalog::Errors::CatalogUnavailableError
    :unavailable
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

  # Exact family price RANGE fact, or nil (no family, range unavailable/conflict/outage, or an
  # unsupported display locale). The authoritative min/max/currency/uom come from the reused
  # FamilyPriceRangeAuthority (exact-price qualifying policy across every active child); the
  # customer-visible display endpoints are reconstructed deterministically from those canonical
  # amounts via the EXISTING PriceDisplayFormatter at the packet locale — never trusted. Equal
  # endpoints stay exact (min == max renders two identical display amounts). Never a Float.
  # Provenance (source + checked_at) is carried verbatim from the SAME authority Result that returned
  # min/max/currency/uom — the planner never re-stamps a literal source or its own clock, so the
  # recorded provenance always belongs to the authority that produced the amounts. EvidencePacketBuilder
  # still validates both against its closed exact source / UTC-timestamp contract (fail-closed on forgery).
  def price_range_fact(family, language) # rubocop:disable Metrics/AbcSize -- a flat authority-call then two-endpoint display assembly
    return nil if family.nil?

    range = range_authority.call(family_code: family[:code])
    return nil unless range.available?

    min_display = format_range_endpoint(family[:code], range.min, range.currency, range.uom, language)
    max_display = format_range_endpoint(family[:code], range.max, range.currency, range.uom, language)
    return nil if min_display.nil? || max_display.nil?

    {
      canonical: { family_code: family[:code], currency: range.currency, min: range.min, max: range.max, uom: range.uom },
      display: { currency: min_display[:currency], min: min_display[:amount], max: max_display[:amount], uom: min_display[:uom] },
      policy_version: min_display[:policy_version],
      source: range.source,
      checked_at: range.checked_at
    }
  end

  # One range endpoint's immutable display view via the shared formatter, or nil on any format failure.
  def format_range_endpoint(family_code, amount, currency, uom, language)
    result = price_formatter.format(
      descriptor: { kind: :price_available, variant_code: family_code, price_list_rate: amount, currency: currency, uom: uom },
      locale: language.to_s
    )
    return nil unless result.ok?

    { currency: result.envelope[:display][:currency], amount: result.envelope[:display][:amount],
      uom: result.envelope[:display][:uom], policy_version: result.envelope[:policy_version] }
  end

  # A bounded product-listing fact. `product` is nil for the broad top-level page, or an exact-resolved
  # { code:, name: } that restricts the page to that one authorized product. Returns nil (fail closed to
  # a handoff) on an empty catalog or catalog outage. The product SET is catalog-authoritative; for
  # product_information the already-authorized page is FILTERED to exactly the subset carrying a bound
  # approved RAG description (a product is never selected from RAG; an undescribed product is dropped),
  # and zero bound descriptions fails closed. returned_count is recomputed to the emitted subset;
  # total_count stays the Catalog-authoritative top-level total; completeness is read from the repository's
  # explicit has_more (the authoritative completeness signal, complete == !has_more), and complete is true
  # only when the original page had no more AND nothing was filtered out — so a filtered page is never
  # claimed as the whole catalogue.
  def listing_fact(descriptions:, product:, item_group: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- three bounded authority branches plus fail-closed metadata gates
    page = if product
             single_product_page(product)
           elsif item_group
             listing_repository.active_top_level(item_group: item_group)
           else
             listing_repository.active_top_level
           end
    return nil if page[:products].empty?

    products = listing_products(page[:products], descriptions)
    return nil if descriptions && products.empty?

    filtered = products.length < page[:returned_count]
    {
      products: products,
      returned_count: products.length,
      total_count: page[:total_count],
      complete: !page[:has_more] && !filtered,
      source: 'catalog_listing_repository',
      checked_at: now_iso8601
    }
  rescue Marine::Catalog::Errors::CatalogUnavailableError
    nil
  end

  # A single exact-resolved product rendered as a one-row, complete page. has_more is false so the
  # page shares the repository's completeness contract (complete == !has_more) that listing_fact reads.
  def single_product_page(product)
    { products: [{ code: product[:code], name: product[:name] }], returned_count: 1, total_count: 1, has_more: false }
  end

  # Fold each authorized catalog row to { code, name } for a names-only listing. For
  # product_information, attach approved RAG descriptions from ONE bounded source call over the whole
  # authorized page and KEEP ONLY the entries that bound a nonblank description — so every emitted
  # product carries its own approved description, and an undescribed (or RAG-only / off-page) product is
  # dropped rather than appended. The source may only annotate a listed code, never add a product.
  def listing_products(products, descriptions)
    return products.map { |product| { code: product[:code], name: product[:name] } } unless descriptions

    bound = description_source.call(products)
    bound = {} unless bound.is_a?(Hash)
    products.filter_map do |product|
      description = bound[product[:code]]
      { code: product[:code], name: product[:name], description: description } if present_string?(description)
    end
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
  def evidence_input(context, goals:, slots: {}, facts: {}, missing: [], presentation_policy: nil) # rubocop:disable Metrics/ParameterLists -- flat evidence-input assembly from already-validated parts
    input = {
      scenario: context.scenario,
      intents: context.intents,
      customer_language: context.language,
      response_goals: goals,
      validated_slots: slots,
      facts: facts,
      missing_slots: missing,
      variant_candidates: []
    }
    input[:presentation_policy] = presentation_policy unless presentation_policy.nil?
    deep_freeze(input)
  end

  def present_string?(value)
    value.is_a?(String) && !value.strip.empty?
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
