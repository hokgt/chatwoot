# Step 18 — deterministic exact-price Evidence renderer.
#
# When a Model 2 exact-price candidate fails ANY acceptance gate — generation failure, the
# deterministic PostGenerationFactValidator, the PersonaValidator, or the semantic EvidenceFactVerifier
# (false / exception / missing / non-callable) — the presenter DISCARDS that untrusted candidate and
# renders a reply from the frozen marine_evidence_v2 Evidence Packet ALONE through this renderer, so the
# customer still receives the authoritative exact price without invoking the legacy path. It is scoped
# to EXACTLY the single response goal answer_price and the single fact key price; any other goal (a
# price_range answer included) or fact is out of scope and yields nil so the presenter keeps that path's
# existing closed fallback.
#
# It is a standalone fail-closed safety component, so it validates the FULL real exact-price Evidence
# contract from the packet ALONE before rendering — never a partial display-only pseudo-packet. It
# mirrors the EvidencePacketBuilder exact-price schema (PRICE_FACT_KEYS / PRICE_CANONICAL_KEYS / the
# price-display-v1 policy_version + catalog_price_repository source + UTC-ISO8601 checked_at), requires
# the authoritative canonical identity/price/currency/UOM, requires the validated marine_catalog variant
# slot whose code the canonical matches, requires the rendered display.product to equal that authoritative
# canonical variant_code (so the identity the reply NAMES is the resolved variant, never a forged token),
# and requires the price-only scenario provenance (intents exactly ["price"]) and the packet
# customer_language — all by PRESENCE and SHAPE only, with NO repository / DB / RAG / provider / formatter
# recompute. A packet missing / malforming any of these fails closed to nil.
#
# Its only business-fact input for the reply text is the authoritative, formatter-validated DISPLAY block
# the EvidencePacketBuilder already reconstructed from the strict canonical facts (product, currency,
# amount, uom) plus the packet customer_language. It renders them through the SAME approved
# price-display-v1 id/en template (marine.catalog.price.price_available) the existing deterministic
# price fallback uses, so the authoritative identity / price / currency / UOM are preserved byte-for-byte
# and never recomputed, reformatted, or invented. It never reads the Model 2 candidate, the raw customer
# request/history, a provider / RAG / repository / DB, and never adds stock/status/quantity,
# warehouse/location, delivery/lead time, discount/promotion, a price comparison/history, or any
# qualitative product claim. The authoritative source / policy_version / checked_at are validated but
# NEVER surfaced in the customer text.
#
# It FAILS CLOSED (returns nil, never repairs) on a non-price, multi-goal, malformed, mutable
# (not deeply frozen), or unsupported-language packet, and never raises. It is pure and safe for
# repeated calls.
class Marine::Backend::ExactPriceEvidenceRenderer
  EVIDENCE_VERSION = 'marine_evidence_v2'.freeze
  PRICE_GOAL = 'answer_price'.freeze
  # The price-only candidate intent the scenario provenance must carry (mirrors the ExecutionPolicy
  # price authorization — the top-level intents set a price packet is built from is exactly ["price"]).
  PRICE_INTENT = 'price'.freeze
  # The currently contract-supported customer languages (mirrors the PriceDisplayFormatter locale
  # contract). An unsupported language is an explicit safe failure — never an invented template.
  SUPPORTED_LANGUAGES = %w[id en].freeze

  # The real exact-price fact contract, mirrored from EvidencePacketBuilder (closed-key, fail-closed).
  # The renderer validates presence and shape from the packet ALONE — it never recomputes a fact.
  PRICE_FACT_KEYS = %i[canonical display policy_version source checked_at].freeze
  PRICE_CANONICAL_KEYS = %i[variant_code currency price_list_rate uom].freeze
  # The exact authoritative display block the renderer may read to build the reply — nothing else.
  DISPLAY_KEYS = %i[product currency amount uom].freeze
  PRICE_SOURCE = 'catalog_price_repository'.freeze
  PRICE_POLICY_VERSION = 'price-display-v1'.freeze
  SLOT_SOURCE = 'marine_catalog'.freeze
  # A finite, non-negative rate shape consistent with the builder's canonical price_list_rate
  # (mirrors EvidencePacketBuilder::RATE_STRING): Integer, finite non-negative BigDecimal, or exact
  # decimal String. Validated for presence/shape only — never reformatted into the reply.
  RATE_STRING = /\A\d+(?:\.\d+)?\z/
  # ISO8601 UTC instant ending in Z (mirrors EvidencePacketBuilder::UTC_ISO8601).
  UTC_ISO8601 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

  # The existing approved deterministic exact-price template (price-display-v1), shared with the
  # legacy PriceReplyComposer fallback so the customer-visible formatting is identical.
  TEMPLATE_KEY = 'marine.catalog.price.price_available'.freeze

  # packet: a frozen marine_evidence_v2 answer_price Evidence Packet.
  # Returns the deterministic reply String, or nil on any non-price/malformed/unsupported outcome.
  def call(packet:)
    return nil unless renderable_packet?(packet)
    return nil unless SUPPORTED_LANGUAGES.include?(packet[:customer_language])

    render(packet[:facts][:price][:display], packet[:customer_language])
  rescue StandardError
    nil
  end

  private

  # In scope ONLY for a DEEPLY FROZEN v2 packet whose sole response goal is answer_price, whose scenario
  # provenance is price-only, that carries a present customer_language, and whose facts carry EXACTLY the
  # price key holding the full real exact-price fact. A price_range answer, a multi-goal packet, a
  # non-price scenario, a mutable pseudo-packet, and every other goal/fact is out of scope.
  def renderable_packet?(packet) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent structural packet guards
    packet.is_a?(Hash) && deeply_frozen?(packet) &&
      packet[:evidence_version] == EVIDENCE_VERSION &&
      packet[:response_goals] == [PRICE_GOAL] &&
      price_only_provenance?(packet[:scenario]) &&
      packet[:customer_language].is_a?(String) &&
      packet[:facts].is_a?(Hash) &&
      packet[:facts].keys == %i[price] &&
      valid_price_fact?(packet[:facts][:price], packet[:validated_slots])
  end

  # The scenario provenance of a price turn carries EXACTLY the price candidate intent.
  def price_only_provenance?(scenario)
    scenario.is_a?(Hash) && scenario[:intents] == [PRICE_INTENT]
  end

  # The full real exact-price fact: EXACTLY { canonical, display, policy_version, source, checked_at },
  # with the authoritative canonical identity/price bound to the validated variant slot, the approved
  # price-display-v1 policy, the catalog_price_repository provenance, a UTC-ISO8601 timestamp, and the
  # authoritative display block. A partial display-only fact fails closed.
  def valid_price_fact?(fact, validated_slots)
    fact.is_a?(Hash) &&
      fact.keys.sort == PRICE_FACT_KEYS.sort &&
      valid_canonical?(fact[:canonical], validated_slots) &&
      valid_display?(fact[:display], fact[:canonical]) &&
      fact[:policy_version] == PRICE_POLICY_VERSION &&
      fact[:source] == PRICE_SOURCE &&
      valid_timestamp?(fact[:checked_at])
  end

  # The authoritative canonical facts: EXACTLY { variant_code, currency, price_list_rate, uom } — the
  # identity/currency/uom are present control-free Strings, the rate a finite non-negative rate shape,
  # and the variant_code matches the validated marine_catalog variant slot.
  def valid_canonical?(canonical, validated_slots)
    canonical.is_a?(Hash) &&
      canonical.keys.sort == PRICE_CANONICAL_KEYS.sort &&
      safe_string?(canonical[:variant_code]) &&
      safe_string?(canonical[:currency]) &&
      safe_string?(canonical[:uom]) &&
      valid_rate?(canonical[:price_list_rate]) &&
      variant_identity_matches?(canonical[:variant_code], validated_slots)
  end

  # The packet must ground the price on a validated marine_catalog variant slot whose code the canonical
  # block matches — so the authoritative identity the reply names is the resolved variant, never forged.
  def variant_identity_matches?(variant_code, validated_slots)
    validated_slots.is_a?(Hash) &&
      (variant = validated_slots[:variant]).is_a?(Hash) &&
      variant[:code] == variant_code &&
      variant[:source] == SLOT_SOURCE
  end

  # The authoritative display block is EXACTLY { product, currency, amount, uom }, each a present,
  # control-free String. A missing/extra key or a blank/control-bearing value fails closed — the
  # renderer never repairs it. The product identity the reply NAMES must equal the authoritative
  # canonical variant_code: the PriceDisplayFormatter emits display.product verbatim from
  # canonical.variant_code, so this equality holds byte-for-byte in every genuine packet and is checkable
  # from the packet ALONE (no formatter/repo/DB recompute). A well-shaped but internally-inconsistent
  # packet (forged display.product) fails closed rather than name a fabricated identity at the real price.
  def valid_display?(display, canonical)
    display.is_a?(Hash) &&
      display.keys.sort == DISPLAY_KEYS.sort &&
      DISPLAY_KEYS.all? { |key| safe_string?(display[key]) } &&
      display[:product] == canonical[:variant_code]
  end

  def valid_rate?(rate)
    case rate
    when Integer then !rate.negative?
    when BigDecimal then rate.finite? && !rate.negative?
    when String then rate.match?(RATE_STRING)
    else false
    end
  end

  def valid_timestamp?(value)
    value.is_a?(String) && value.match?(UTC_ISO8601)
  end

  def safe_string?(value)
    value.is_a?(String) && !value.strip.empty? && !value.match?(/[[:cntrl:]]/)
  end

  # Every nested container, key, and scalar must be frozen — a mutable or shallow-frozen pseudo-packet
  # (top frozen, a nested container mutable) fails closed (mirrors the presenter's deep-frozen gate).
  def deeply_frozen?(value)
    return false unless value.frozen?

    case value
    when Hash then value.all? { |key, child| key.frozen? && deeply_frozen?(child) }
    when Array then value.all? { |child| deeply_frozen?(child) }
    else true
    end
  end

  # The approved price-display-v1 template in the packet's supported language, built from the
  # authoritative display facts ALONE. A missing locale key fails closed (never an invented sentence).
  def render(display, language)
    text = I18n.t(TEMPLATE_KEY, product: display[:product], currency: display[:currency],
                                amount: display[:amount], uom: display[:uom],
                                locale: language, default: nil)
    return nil unless text.is_a?(String) && !text.strip.empty?

    text
  end
end
