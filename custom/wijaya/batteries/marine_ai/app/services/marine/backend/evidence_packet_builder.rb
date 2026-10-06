# Fase 3A-1 (isolated / mock-only) — marine_evidence_v2 PRODUCT Evidence Packet builder.
#
# The Evidence Packet is the SOLE presentation boundary: it is the only thing Model 2 ever
# sees. This builder folds a planner-produced evidence input into a deeply immutable,
# closed-key/closed-enum, serialization-ready packet with hard bounds (A8-01). It is a PRODUCT
# packet ONLY — price/catalog/product-overview, clarification/handoff, and combined price+stock.
# It NEVER emits the reserved ERP blocks (customer_resolution / payment_policy), no null-fact
# placeholders, no raw DB row / raw ERP response / credentials / chain-of-thought / Model 1
# prose.
#
# It is a CLOSED, FAIL-CLOSED validator, not a permissive filter: a malformed programmer-supplied
# evidence input raises InvalidEvidenceInputError and NEVER yields a partly-authoritative packet.
# It rejects unknown top-level/nested keys, unknown/overflow goals/intents, a top-level intents set
# that is not the exact ExecutionPolicy-authorized executable array (Phase 1: exactly ["price"]), a
# malformed scenario key, malformed slots, unknown fact keys, a fact whose strict shape/source/policy/
# timestamp is wrong, a fact that does not match its resolved variant slot, and any fact/intent/goal
# incoherence. Execution authorization is backend-policy-owned (Marine::Backend::ExecutionPolicy);
# scenario carries only provenance ({ key, intents }), never capabilities. Repository failure is
# represented UPSTREAM by no fact + handoff (the planner), never by a repaired fact here. Only free
# catalog display text (a product/variant name, an item group, attribute values) is length-bounded
# rather than rejected; every authoritative value is validated exactly.
#
# It performs NO provider call, NO DB access, NO state read/write, and has ZERO runtime wiring; the
# clock is injected for deterministic timestamps.
class Marine::Backend::EvidencePacketBuilder # rubocop:disable Metrics/ClassLength -- a flat sequence of independent closed-field validators
  Schema = Marine::Decision::Schema
  ExecutionPolicy = Marine::Backend::ExecutionPolicy

  EVIDENCE_VERSION = 'marine_evidence_v2'.freeze

  # Exhaustive top-level input keys (the ProductExecutionPlanner output contract). Anything else
  # fails closed.
  INPUT_KEYS = %i[scenario intents customer_language response_goals validated_slots facts
                  missing_slots variant_candidates].freeze

  # Closed response-goal enum (A8-01). answer_product_listing / answer_product_information are the
  # Phase 3 bounded-catalog answers. answer_payment_terms / clarify_payment are reserved for 3B.
  RESPONSE_GOALS = %w[
    answer_price answer_price_range answer_stock answer_product_overview answer_product_listing answer_product_information
    clarify_product clarify_variant clarify_ambiguous_variant handoff
  ].freeze

  # The candidate intents / capability members are drawn from the Schema intent vocabulary.
  INTENTS = Schema::INTENTS

  # The two slots a 3A product turn may miss (product contract + variant_input).
  MISSING_SLOTS = %w[product variant_input].freeze

  # Closed slot key sets (reject unknown nested keys). Every slot's source is a closed enum.
  PRODUCT_SLOT_KEYS = %i[code name item_group attributes source].freeze
  VARIANT_SLOT_KEYS = %i[code display_name attributes resolution_status source].freeze
  SLOT_SOURCE = 'marine_catalog'.freeze
  RESOLVED_STATUS = 'resolved'.freeze

  # Closed fact shapes.
  PRICE_FACT_KEYS = %i[canonical display policy_version source checked_at].freeze
  PRICE_CANONICAL_KEYS = %i[variant_code currency price_list_rate uom].freeze
  PRICE_DISPLAY_KEYS = %i[product currency amount uom].freeze
  PRICE_SOURCE = 'catalog_price_repository'.freeze
  STOCK_FACT_KEYS = %i[status source checked_at].freeze
  STOCK_STATUSES = %w[available unavailable].freeze
  STOCK_SOURCE = 'stock_repository'.freeze

  # Closed family price-RANGE fact (Phase 5). The canonical block carries the authoritative family
  # code + exact min/max amounts + currency/uom; the display block (min/max display amounts) is NOT
  # trusted but reconstructed from the canonical via the PriceDisplayFormatter at the packet locale.
  PRICE_RANGE_FACT_KEYS = %i[canonical display policy_version source checked_at].freeze
  PRICE_RANGE_CANONICAL_KEYS = %i[family_code currency min max uom].freeze
  PRICE_RANGE_DISPLAY_KEYS = %i[currency min max uom].freeze
  PRICE_RANGE_SOURCE = 'catalog_price_range_repository'.freeze

  # Closed product-listing fact (Phase 3). A bounded page of active top-level catalog products plus
  # EXACT completeness metadata (returned_count, optional total_count, complete boolean). Each product
  # carries a code + optional display name; a per-product description is REQUIRED (nonblank) under the
  # answer_product_information goal (every product described) and FORBIDDEN under a names-only listing.
  LISTING_FACT_KEYS = %i[products returned_count total_count complete source checked_at].freeze
  LISTING_PRODUCT_KEYS = %i[code name description].freeze
  LISTING_SOURCE = 'catalog_listing_repository'.freeze
  # The two Phase-3 listing goals; a product_listing fact exists iff one of these is a response goal.
  LISTING_GOALS = %w[answer_product_listing answer_product_information].freeze
  # The Phase-3 listing candidate intents; a product_listing fact requires one of these in intents.
  LISTING_INTENTS = %w[product_listing product_information].freeze

  # An exact, non-negative decimal string (mirrors PriceDisplayFormatter::AMOUNT_STRING) — a
  # string rate must be losslessly representable; an Integer / finite BigDecimal is also accepted.
  RATE_STRING = /\A\d+(?:\.\d+)?\z/
  # ISO8601 UTC instant ending in Z (no offset form is accepted for a fact/packet timestamp).
  UTC_ISO8601 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

  # Always-forbidden claim classes; price/stock are added when their fact is unauthorized/absent.
  BASE_PROHIBITED_CLAIMS = %w[exact_stock_quantity warehouse_location delivery_date unverified_discount].freeze

  RESPONSE_CONSTRAINTS = { max_paragraphs: 2, role: 'marine_sales_assistant', handoff_self_reference: true }.freeze

  # Concrete bounds (A8-01).
  MAX_RESPONSE_GOALS = 4
  MAX_FACTS = 4
  MAX_INTENTS = Schema::MAX_INTENTS
  MAX_VARIANT_CANDIDATES = 5
  MAX_MISSING_SLOTS = 2
  MAX_PROHIBITED_CLAIMS = 16
  MAX_STRING_BYTES = 256
  MAX_CODE_BYTES = 120
  MAX_ATTRIBUTES = 16
  MAX_ATTRIBUTE_KEY_BYTES = 80
  MAX_ATTRIBUTE_VALUE_BYTES = 80
  MAX_PACKET_BYTES = 16 * 1024
  # Bounded listing page (aligned with ProductListingRepository::MAX_PAGE) and a per-product
  # description cap, both chosen so a full page fits under MAX_PACKET_BYTES (the enforce_ceiling!
  # backstop still fails closed if an oversized page/description would exceed it).
  MAX_LISTING_PRODUCTS = 20
  MAX_DESCRIPTION_BYTES = 300

  # Raised (fail closed) when a programmer-supplied evidence input violates the closed contract.
  # It carries a FIXED message only — never the offending value / raw provider prose.
  class InvalidEvidenceInputError < StandardError
    def initialize(message = 'The evidence input could not be built into a closed packet')
      super
    end
  end

  # Raised (fail closed) if an assembled packet exceeds the serialized byte ceiling despite the
  # per-field caps — a backstop, never expected under the caps above.
  class PacketTooLargeError < StandardError; end

  # The PriceDisplayFormatter is the SOLE display authority: the price display block is never
  # trusted from the input but reconstructed here from the strict canonical facts + the packet
  # locale, so a forged display currency/amount can never pass while the canonical is unchanged.
  def initialize(clock: nil, price_formatter: nil)
    @clock = clock || -> { Time.current }
    @price_formatter = price_formatter || Marine::Catalog::PriceDisplayFormatter.new
  end

  # evidence_input: the ProductExecutionPlanner output (or an equivalent test-built hash).
  # Raises InvalidEvidenceInputError on any closed-contract violation.
  def build(evidence_input:)
    input = validated_input(evidence_input)
    intents = intents(input[:intents])
    scenario = scenario(input[:scenario], intents)
    goals = response_goals(input[:response_goals])
    # Canonicalize the customer language BEFORE the facts: a price fact's display block is derived
    # from the formatter at this locale, so the locale must be resolved first.
    language = language(input[:customer_language])
    slots = validated_slots(input[:validated_slots])
    facts = facts(input[:facts], slots, language, goals)
    ensure_coherent!(facts, goals, intents, slots)

    packet = assemble(scenario, goals, slots, facts, input[:missing_slots], input[:variant_candidates])
    packet[:customer_language] = language unless language.nil?

    enforce_ceiling!(deep_freeze(packet))
  end

  private

  def validated_input(input)
    raise invalid unless input.is_a?(Hash)

    reject_unknown_keys!(input, INPUT_KEYS)
    # Execution authorization is the ONE backend policy: the COMPLETE top-level intents set — as
    # submitted, never deduped/sorted — must be exactly ONE ExecutionPolicy-authorized product intent
    # (["price"], ["product_listing"], or ["product_information"]). ["price"] still passes, so the
    # exact-price packet contract is unchanged.
    raise invalid unless ExecutionPolicy.product_authorized?(input[:intents])

    input
  end

  def assemble(scenario, goals, slots, facts, missing, candidates) # rubocop:disable Metrics/ParameterLists -- a flat packet assembly from already-validated parts
    {
      evidence_version: EVIDENCE_VERSION,
      generated_at: now_iso8601,
      response_goals: goals,
      scenario: scenario,
      validated_slots: slots,
      facts: facts,
      missing_slots: missing_slots(missing),
      variant_candidates: variant_candidates(candidates),
      prohibited_claims: prohibited_claims(facts),
      response_constraints: RESPONSE_CONSTRAINTS.dup
    }
  end

  # Non-empty, deduped, enum-closed goals within the ceiling. An unknown goal or an overflow
  # (too many distinct goals) fails closed.
  def response_goals(goals)
    raise invalid unless goals.is_a?(Array) && !goals.empty?

    deduped = goals.uniq
    raise invalid unless deduped.all? { |goal| RESPONSE_GOALS.include?(goal) }
    raise invalid if deduped.length > MAX_RESPONSE_GOALS

    deduped.map(&:dup)
  end

  # Deduped candidate intents, each in the Schema vocabulary, within the intent ceiling.
  def intents(intents)
    raise invalid unless intents.is_a?(Array)

    deduped = intents.uniq
    raise invalid unless deduped.all? { |intent| INTENTS.include?(intent) }
    raise invalid if deduped.length > MAX_INTENTS

    deduped.map(&:dup)
  end

  # scenario { key, intents }: a canonical provenance key plus the turn's candidate intents
  # (provenance of what was asked, NOT authorization — execution authorization is backend-policy-owned
  # by ExecutionPolicy). A `capabilities` subkey is rejected as an unknown key.
  def scenario(scenario, intents)
    raise invalid unless scenario.is_a?(Hash)

    reject_unknown_keys!(scenario, %i[key])
    key = required_string!(scenario[:key], MAX_CODE_BYTES)
    raise invalid unless key.match?(Schema::SCENARIO_KEY_PATTERN)

    { key: key, intents: intents }
  end

  def validated_slots(slots)
    return {} if slots.nil? || slots == {}
    raise invalid unless slots.is_a?(Hash)

    reject_unknown_keys!(slots, %i[product variant])
    result = {}
    result[:product] = product_slot(slots[:product]) if slots.key?(:product)
    result[:variant] = variant_slot(slots[:variant]) if slots.key?(:variant)
    result
  end

  def product_slot(slot)
    raise invalid unless slot.is_a?(Hash)

    reject_unknown_keys!(slot, PRODUCT_SLOT_KEYS)
    compact_slot(
      code: required_string!(slot[:code], MAX_CODE_BYTES),
      name: optional_bounded_string(slot[:name], MAX_STRING_BYTES),
      item_group: optional_bounded_string(slot[:item_group], MAX_STRING_BYTES),
      attributes: attributes(slot[:attributes]),
      source: slot_source!(slot[:source])
    )
  end

  def variant_slot(slot)
    raise invalid unless slot.is_a?(Hash)

    reject_unknown_keys!(slot, VARIANT_SLOT_KEYS)
    compact_slot(
      code: required_string!(slot[:code], MAX_CODE_BYTES),
      display_name: optional_bounded_string(slot[:display_name], MAX_STRING_BYTES),
      attributes: attributes(slot[:attributes]),
      resolution_status: resolution_status!(slot[:resolution_status]),
      source: slot_source!(slot[:source])
    )
  end

  def slot_source!(source)
    raise invalid unless source == SLOT_SOURCE

    source.dup
  end

  # resolution_status is optional; when present it must be the closed 'resolved' value.
  def resolution_status!(status)
    return nil if status.nil?
    raise invalid unless status == RESOLVED_STATUS

    status.dup
  end

  # Drop nil scalar values (omission, never a null placeholder), but always keep an
  # attributes hash (possibly empty) so its bound is explicit.
  def compact_slot(fields)
    attributes = fields.delete(:attributes) || {}
    fields.compact.merge(attributes: attributes)
  end

  # Free catalog attribute map (dynamic attribute names) — bounded/capped rather than rejected.
  def attributes(attributes)
    return {} if attributes.nil?
    raise invalid unless attributes.is_a?(Hash)

    attributes.first(MAX_ATTRIBUTES).each_with_object({}) do |(key, value), acc|
      bounded_key = bounded_bytes(key.to_s, MAX_ATTRIBUTE_KEY_BYTES)
      bounded_value = bounded_bytes(value.to_s, MAX_ATTRIBUTE_VALUE_BYTES)
      acc[bounded_key] = bounded_value unless bounded_key.empty?
    end
  end

  # Closed facts: price/stock (over a resolved variant slot) and the catalog-wide product_listing,
  # each strictly validated. Unknown fact keys fail closed.
  def facts(facts, slots, language, goals) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize -- a flat dispatch over the closed fact keys
    return {} if facts.nil? || facts == {}
    raise invalid unless facts.is_a?(Hash)

    reject_unknown_keys!(facts, %i[price price_range stock product_listing])
    variant_code = slots.dig(:variant, :code)
    result = {}
    result[:price] = price_fact(facts[:price], variant_code, language) if facts.key?(:price)
    result[:price_range] = price_range_fact(facts[:price_range], slots, language) if facts.key?(:price_range)
    result[:stock] = stock_fact(facts[:stock], variant_code) if facts.key?(:stock)
    result[:product_listing] = product_listing_fact(facts[:product_listing], goals) if facts.key?(:product_listing)
    raise invalid if result.length > MAX_FACTS

    result
  end

  # A price fact only exists over a RESOLVED variant slot whose code the canonical block matches;
  # the display block and policy_version are NOT trusted from the input but reconstructed from the
  # strict canonical facts + packet locale via the PriceDisplayFormatter, then required to equal the
  # submitted block exactly — so a forged display currency/amount cannot pass with a valid canonical.
  def price_fact(fact, variant_code, language)
    raise invalid unless fact.is_a?(Hash)
    raise invalid if variant_code.nil?

    reject_unknown_keys!(fact, PRICE_FACT_KEYS)
    canonical = price_canonical(fact[:canonical], variant_code)
    envelope = price_envelope!(canonical, language)
    {
      canonical: canonical,
      display: price_display!(fact[:display], envelope),
      policy_version: exact!(fact[:policy_version], envelope[:policy_version]),
      source: exact!(fact[:source], PRICE_SOURCE),
      checked_at: utc_timestamp!(fact[:checked_at])
    }
  end

  def price_canonical(canonical, variant_code)
    raise invalid unless canonical.is_a?(Hash)

    reject_unknown_keys!(canonical, PRICE_CANONICAL_KEYS)
    code = required_string!(canonical[:variant_code], MAX_CODE_BYTES)
    raise invalid unless code == variant_code

    {
      variant_code: code,
      currency: required_string!(canonical[:currency], MAX_STRING_BYTES),
      price_list_rate: rate!(canonical[:price_list_rate]),
      uom: required_string!(canonical[:uom], MAX_STRING_BYTES)
    }
  end

  # Reconstruct the formatter's immutable display envelope from the strict canonical facts at the
  # packet locale. A price fact REQUIRES a supported formatter locale; a missing locale or any
  # formatter failure (unsupported locale/currency/uom, non-exact rate) fails closed.
  def price_envelope!(canonical, language)
    raise invalid if language.nil?

    result = @price_formatter.format(descriptor: formatter_descriptor(canonical), locale: language)
    raise invalid unless result.ok?

    result.envelope
  end

  def formatter_descriptor(canonical)
    {
      kind: :price_available,
      variant_code: canonical[:variant_code],
      price_list_rate: canonical[:price_list_rate],
      currency: canonical[:currency],
      uom: canonical[:uom]
    }
  end

  # The submitted display block must exactly equal the formatter's derived display view — a forged
  # amount, currency, product, or uom fails closed. Returns a fresh owned copy of the display.
  def price_display!(display, envelope)
    raise invalid unless display.is_a?(Hash)

    reject_unknown_keys!(display, PRICE_DISPLAY_KEYS)
    expected = envelope[:display]
    submitted = { product: display[:product], currency: display[:currency], amount: display[:amount], uom: display[:uom] }
    raise invalid unless submitted == expected

    submitted.transform_values(&:dup)
  end

  # A family price-RANGE fact only exists over a validated PRODUCT slot whose family code the canonical
  # block matches; the display endpoints are NOT trusted from the input but reconstructed from the
  # strict canonical min/max + packet locale via the PriceDisplayFormatter, then required to equal the
  # submitted block exactly — so a forged display amount/currency/uom cannot pass with a valid canonical.
  def price_range_fact(fact, slots, language)
    raise invalid unless fact.is_a?(Hash)

    family_code = slots.dig(:product, :code)
    raise invalid if family_code.nil?

    reject_unknown_keys!(fact, PRICE_RANGE_FACT_KEYS)
    canonical = price_range_canonical(fact[:canonical], family_code)
    display, policy_version = price_range_display!(fact[:display], canonical, language)
    {
      canonical: canonical,
      display: display,
      policy_version: exact!(fact[:policy_version], policy_version),
      source: exact!(fact[:source], PRICE_RANGE_SOURCE),
      checked_at: utc_timestamp!(fact[:checked_at])
    }
  end

  # Canonical range: the family code (bound to the product slot), a homogeneous currency/uom, and an
  # exact, non-negative min <= max (both exact decimals, never a Float). Equal endpoints are allowed.
  def price_range_canonical(canonical, family_code)
    raise invalid unless canonical.is_a?(Hash)

    reject_unknown_keys!(canonical, PRICE_RANGE_CANONICAL_KEYS)
    code = required_string!(canonical[:family_code], MAX_CODE_BYTES)
    raise invalid unless code == family_code

    min = rate!(canonical[:min])
    max = rate!(canonical[:max])
    raise invalid unless decimal(min) <= decimal(max)

    { family_code: code, currency: required_string!(canonical[:currency], MAX_STRING_BYTES),
      min: min, max: max, uom: required_string!(canonical[:uom], MAX_STRING_BYTES) }
  end

  # Reconstruct each endpoint's immutable display view from the canonical facts at the packet locale,
  # then require the submitted display to equal it exactly. Returns [display_block, policy_version].
  def price_range_display!(display, canonical, language) # rubocop:disable Metrics/AbcSize -- a flat reconstruct-both-endpoints-then-compare validation
    raise invalid unless display.is_a?(Hash)
    raise invalid if language.nil?

    reject_unknown_keys!(display, PRICE_RANGE_DISPLAY_KEYS)
    min_env = range_endpoint_envelope!(canonical, canonical[:min], language)
    max_env = range_endpoint_envelope!(canonical, canonical[:max], language)
    expected = { currency: min_env[:display][:currency], min: min_env[:display][:amount],
                 max: max_env[:display][:amount], uom: min_env[:display][:uom] }
    submitted = { currency: display[:currency], min: display[:min], max: display[:max], uom: display[:uom] }
    raise invalid unless submitted == expected

    [submitted.transform_values(&:dup), min_env[:policy_version]]
  end

  def range_endpoint_envelope!(canonical, amount, language)
    result = @price_formatter.format(descriptor: range_formatter_descriptor(canonical, amount), locale: language)
    raise invalid unless result.ok?

    result.envelope
  end

  def range_formatter_descriptor(canonical, amount)
    { kind: :price_available, variant_code: canonical[:family_code],
      price_list_rate: amount, currency: canonical[:currency], uom: canonical[:uom] }
  end

  def decimal(value)
    BigDecimal(value.to_s)
  end

  # A binary stock fact only exists over a resolved variant slot.
  def stock_fact(fact, variant_code)
    raise invalid unless fact.is_a?(Hash)
    raise invalid if variant_code.nil?

    reject_unknown_keys!(fact, STOCK_FACT_KEYS)
    raise invalid unless STOCK_STATUSES.include?(fact[:status])

    { status: fact[:status].dup, source: exact!(fact[:source], STOCK_SOURCE), checked_at: utc_timestamp!(fact[:checked_at]) }
  end

  # A bounded product-listing fact: the authorized returned page plus EXACT completeness metadata.
  # Each product carries a validated code + optional display name; a per-product description is
  # permitted ONLY under the answer_product_information goal. returned_count must equal the page size;
  # when complete, total_count must equal returned_count; when not complete, total_count is an Integer
  # strictly greater than returned_count (or omitted when it could not be obtained safely) — so the
  # completeness/count claim the packet carries is always exact.
  def product_listing_fact(fact, goals)
    raise invalid unless fact.is_a?(Hash)

    reject_unknown_keys!(fact, LISTING_FACT_KEYS)
    products = listing_products(fact[:products], information: goals.include?('answer_product_information'))
    returned = listing_count!(fact[:returned_count], products.length)
    complete = boolean!(fact[:complete])
    {
      products: products,
      returned_count: returned,
      total_count: listing_total!(fact[:total_count], returned, complete),
      complete: complete,
      source: exact!(fact[:source], LISTING_SOURCE),
      checked_at: utc_timestamp!(fact[:checked_at])
    }.compact
  end

  # Non-empty, bounded, duplicate-free products. Each is a closed { code, name?, description? }; the
  # code is a required authoritative value and the name is free display text. The description obeys the
  # goal shape INDEPENDENTLY of the planner: under answer_product_information EVERY product must carry a
  # nonblank description (so an undescribed information product fails closed), and under a names-only
  # answer_product_listing a description is forbidden.
  def listing_products(products, information:)
    raise invalid unless products.is_a?(Array) && !products.empty?
    raise invalid if products.length > MAX_LISTING_PRODUCTS

    seen = []
    products.map do |entry|
      raise invalid unless entry.is_a?(Hash)

      reject_unknown_keys!(entry, LISTING_PRODUCT_KEYS)
      code = required_string!(entry[:code], MAX_CODE_BYTES)
      raise invalid if seen.include?(code)

      seen << code
      { code: code, name: optional_bounded_string(entry[:name], MAX_STRING_BYTES),
        description: listing_description!(entry[:description], information) }.compact
    end
  end

  # The goal-shaped description discipline. Under answer_product_information a description is REQUIRED
  # and nonblank (a blank/absent description fails closed, so no information packet with an undescribed
  # product can build). Under a names-only answer_product_listing a description is FORBIDDEN. In both
  # cases the builder enforces the shape itself rather than trusting the planner to have filtered.
  def listing_description!(value, information)
    return required_description!(value) if information
    return nil if value.nil?

    raise invalid
  end

  def required_description!(value)
    description = optional_bounded_string(value, MAX_DESCRIPTION_BYTES)
    raise invalid if description.nil?

    description
  end

  # returned_count must be the exact size of the returned page.
  def listing_count!(value, expected)
    raise invalid unless value.is_a?(Integer) && value == expected

    value
  end

  # total_count discipline: when complete it must equal returned_count (the page is the whole set);
  # when not complete it is an Integer strictly greater than returned_count, or nil (omitted) when it
  # was not obtained safely.
  def listing_total!(value, returned, complete)
    if complete
      raise invalid unless value == returned

      return returned
    end
    return nil if value.nil?
    raise invalid unless value.is_a?(Integer) && value > returned

    value
  end

  def boolean!(value)
    raise invalid unless [true, false].include?(value)

    value
  end

  # Fact/intent/goal coherence: a price fact exists iff answer_price is a goal AND price is a
  # candidate intent; likewise stock/answer_stock. Repository failure is a no-fact handoff, never a
  # fact with an incoherent goal set. answer_product_overview requires authoritative validated
  # product evidence (at minimum a validated product slot) — it is never emitted over an empty
  # slot/fact packet Model 2 could hallucinate from.
  def ensure_coherent!(facts, goals, intents, slots) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize -- a flat sequence of independent fact/goal/slot coherence guards
    raise invalid if facts.key?(:price) != goals.include?('answer_price')
    raise invalid if facts.key?(:price) && intents.exclude?('price')
    # A price_range fact exists iff answer_price_range is a goal AND price_range was a candidate
    # intent AND a validated product (family) slot grounds it.
    raise invalid if facts.key?(:price_range) != goals.include?('answer_price_range')
    raise invalid if facts.key?(:price_range) && intents.exclude?('price_range')
    raise invalid if facts.key?(:price_range) && !slots.key?(:product)
    raise invalid if facts.key?(:stock) != goals.include?('answer_stock')
    raise invalid if facts.key?(:stock) && intents.exclude?('stock')
    raise invalid if goals.include?('answer_product_overview') && !slots.key?(:product)
    # A product_listing fact exists iff a listing goal is present AND a listing intent was asked.
    raise invalid if facts.key?(:product_listing) != goals.intersect?(LISTING_GOALS)
    raise invalid if facts.key?(:product_listing) && !intents.intersect?(LISTING_INTENTS)
  end

  def missing_slots(slots)
    return [] if slots.nil?
    raise invalid unless slots.is_a?(Array)

    filtered = slots.uniq.select { |slot| MISSING_SLOTS.include?(slot) }
    raise invalid if filtered.length != slots.uniq.length
    raise invalid if filtered.length > MAX_MISSING_SLOTS

    filtered.map(&:dup)
  end

  def variant_candidates(candidates)
    return [] if candidates.nil?
    raise invalid unless candidates.is_a?(Array)
    raise invalid if candidates.length > MAX_VARIANT_CANDIDATES

    candidates.map { |candidate| required_string!(candidate, MAX_CODE_BYTES) }
  end

  # Base claims + price/stock whenever that fact is absent/unauthorized (omission rule). A price_range
  # fact authorizes stating the range endpoints, so it also lifts the generic 'price' prohibition.
  def prohibited_claims(facts)
    claims = BASE_PROHIBITED_CLAIMS.dup
    claims << 'price' unless facts.key?(:price) || facts.key?(:price_range)
    claims << 'stock' unless facts.key?(:stock)
    claims.uniq.first(MAX_PROHIBITED_CLAIMS)
  end

  def language(value)
    return nil if value.nil?

    optional_bounded_string(value, MAX_STRING_BYTES)
  end

  # A required, nonblank, control-free String within the byte bound — returns a fresh owned copy.
  def required_string!(value, limit)
    raise invalid unless value.is_a?(String)

    cleaned = value.gsub(/[[:cntrl:]]/, ' ').strip
    raise invalid if cleaned.empty? || cleaned.bytesize > limit

    cleaned
  end

  # Optional free display text: nil stays nil; a non-String fails closed; a String is sanitized
  # and length-bounded (truncated, never rejected — it is not an authoritative value).
  def optional_bounded_string(value, limit)
    return nil if value.nil?
    raise invalid unless value.is_a?(String)

    cleaned = value.gsub(/[[:cntrl:]]/, ' ').strip
    cleaned.empty? ? nil : bounded_bytes(cleaned, limit)
  end

  def exact!(value, expected)
    raise invalid unless value == expected

    value.dup
  end

  # A finite, non-negative rate: a non-negative Integer, a finite non-negative BigDecimal, or an
  # exact decimal String. A Float (no exactness guarantee), a negative, or anything else fails
  # closed.
  def rate!(rate)
    case rate
    when Integer then valid_integer_rate?(rate) ? rate : raise(invalid)
    when BigDecimal then valid_decimal_rate?(rate) ? rate : raise(invalid)
    when String then rate.match?(RATE_STRING) ? rate.dup : raise(invalid)
    else raise invalid
    end
  end

  def valid_integer_rate?(rate) = !rate.negative?

  def valid_decimal_rate?(rate) = rate.finite? && !rate.negative?

  def utc_timestamp!(value)
    raise invalid unless value.is_a?(String) && value.match?(UTC_ISO8601)

    Time.iso8601(value)
    value.dup
  rescue ArgumentError
    raise invalid
  end

  # Truncate to a byte ceiling without splitting a multibyte character.
  def bounded_bytes(string, limit)
    return string if string.bytesize <= limit

    string.byteslice(0, limit).scrub('')
  end

  def reject_unknown_keys!(hash, allowed)
    stringified = hash.keys.map(&:to_s)
    raise invalid unless (stringified - allowed.map(&:to_s)).empty?
    raise invalid if stringified.uniq.length != stringified.length
  end

  def now_iso8601 = @clock.call.utc.iso8601

  def enforce_ceiling!(packet)
    raise PacketTooLargeError if JSON.generate(packet).bytesize > MAX_PACKET_BYTES

    packet
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end

  def invalid
    InvalidEvidenceInputError.new
  end
end
