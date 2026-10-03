# Fase 3A-1 (isolated / mock-only) — marine_evidence_v1 PRODUCT Evidence Packet builder.
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
# It rejects unknown top-level/nested keys, unknown/overflow goals/intents/capabilities, a
# malformed scenario key, scenario intents not a subset of capabilities, malformed slots, unknown
# fact keys, a fact whose strict shape/source/policy/timestamp is wrong, a fact that does not match
# its resolved variant slot, and any fact/intent/goal incoherence. Repository failure is
# represented UPSTREAM by no fact + handoff (the planner), never by a repaired fact here. Only free
# catalog display text (a product/variant name, an item group, attribute values) is length-bounded
# rather than rejected; every authoritative value is validated exactly.
#
# It performs NO provider call, NO DB access, NO state read/write, and has ZERO runtime wiring; the
# clock is injected for deterministic timestamps.
class Marine::Backend::EvidencePacketBuilder # rubocop:disable Metrics/ClassLength -- a flat sequence of independent closed-field validators
  Schema = Marine::Decision::Schema

  EVIDENCE_VERSION = 'marine_evidence_v1'.freeze

  # Exhaustive top-level input keys (the ProductExecutionPlanner output contract). Anything else
  # fails closed.
  INPUT_KEYS = %i[scenario intents customer_language response_goals validated_slots facts
                  missing_slots variant_candidates].freeze

  # Closed response-goal enum (A8-01). answer_payment_terms / clarify_payment are reserved for 3B.
  RESPONSE_GOALS = %w[
    answer_price answer_stock answer_product_overview
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
  MAX_CAPABILITIES = INTENTS.length
  MAX_VARIANT_CANDIDATES = 5
  MAX_MISSING_SLOTS = 2
  MAX_PROHIBITED_CLAIMS = 16
  MAX_STRING_BYTES = 256
  MAX_CODE_BYTES = 120
  MAX_ATTRIBUTES = 16
  MAX_ATTRIBUTE_KEY_BYTES = 80
  MAX_ATTRIBUTE_VALUE_BYTES = 80
  MAX_PACKET_BYTES = 16 * 1024

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
    input = evidence_input
    raise invalid unless input.is_a?(Hash)

    reject_unknown_keys!(input, INPUT_KEYS)

    intents = intents(input[:intents])
    scenario = scenario(input[:scenario], intents)
    goals = response_goals(input[:response_goals])
    # Canonicalize the customer language BEFORE the facts: a price fact's display block is derived
    # from the formatter at this locale, so the locale must be resolved first.
    language = language(input[:customer_language])
    slots = validated_slots(input[:validated_slots])
    facts = facts(input[:facts], slots, language)
    ensure_coherent!(facts, goals, intents, slots)

    packet = assemble(scenario, goals, slots, facts, input[:missing_slots], input[:variant_candidates])
    packet[:customer_language] = language unless language.nil?

    enforce_ceiling!(deep_freeze(packet))
  end

  private

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

  # scenario { key, intents, capabilities }: a canonical key, capabilities a closed subset of the
  # intent vocabulary, and the candidate intents a subset of the capabilities (per-scenario
  # execution authority).
  def scenario(scenario, intents)
    raise invalid unless scenario.is_a?(Hash)

    reject_unknown_keys!(scenario, %i[key capabilities])
    key = required_string!(scenario[:key], MAX_CODE_BYTES)
    raise invalid unless key.match?(Schema::SCENARIO_KEY_PATTERN)

    capabilities = capabilities(scenario[:capabilities])
    raise invalid unless (intents - capabilities).empty?

    { key: key, intents: intents, capabilities: capabilities }
  end

  # Capabilities must be a non-empty, closed subset of the intent vocabulary. An empty capability
  # list (A3-04 capability kosong) fails closed — a scenario with no authority executes nothing.
  def capabilities(capabilities)
    raise invalid unless capabilities.is_a?(Array) && !capabilities.empty?

    deduped = capabilities.uniq
    raise invalid unless deduped.all? { |capability| INTENTS.include?(capability) }
    raise invalid if deduped.length > MAX_CAPABILITIES

    deduped.map(&:dup)
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

  # Closed facts: only price/stock, each strictly validated. Unknown fact keys fail closed.
  def facts(facts, slots, language)
    return {} if facts.nil? || facts == {}
    raise invalid unless facts.is_a?(Hash)

    reject_unknown_keys!(facts, %i[price stock])
    variant_code = slots.dig(:variant, :code)
    result = {}
    result[:price] = price_fact(facts[:price], variant_code, language) if facts.key?(:price)
    result[:stock] = stock_fact(facts[:stock], variant_code) if facts.key?(:stock)
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

  # A binary stock fact only exists over a resolved variant slot.
  def stock_fact(fact, variant_code)
    raise invalid unless fact.is_a?(Hash)
    raise invalid if variant_code.nil?

    reject_unknown_keys!(fact, STOCK_FACT_KEYS)
    raise invalid unless STOCK_STATUSES.include?(fact[:status])

    { status: fact[:status].dup, source: exact!(fact[:source], STOCK_SOURCE), checked_at: utc_timestamp!(fact[:checked_at]) }
  end

  # Fact/intent/goal coherence: a price fact exists iff answer_price is a goal AND price is a
  # candidate intent; likewise stock/answer_stock. Repository failure is a no-fact handoff, never a
  # fact with an incoherent goal set. answer_product_overview requires authoritative validated
  # product evidence (at minimum a validated product slot) — it is never emitted over an empty
  # slot/fact packet Model 2 could hallucinate from.
  def ensure_coherent!(facts, goals, intents, slots) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent fact/goal/slot coherence guards
    raise invalid if facts.key?(:price) != goals.include?('answer_price')
    raise invalid if facts.key?(:price) && intents.exclude?('price')
    raise invalid if facts.key?(:stock) != goals.include?('answer_stock')
    raise invalid if facts.key?(:stock) && intents.exclude?('stock')
    raise invalid if goals.include?('answer_product_overview') && !slots.key?(:product)
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

  # Base claims + price/stock whenever that fact is absent/unauthorized (omission rule).
  def prohibited_claims(facts)
    claims = BASE_PROHIBITED_CLAIMS.dup
    claims << 'price' unless facts.key?(:price)
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
