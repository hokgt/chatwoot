# Checkpoint B — deterministic family price-RANGE Evidence renderer.
#
# When a Model 2 answer_price_range candidate fails ANY acceptance gate — generation failure, the
# deterministic PostGenerationFactValidator, the PersonaValidator, or the semantic EvidenceFactVerifier
# (false / exception / missing / non-callable) — the presenter DISCARDS that untrusted candidate and
# renders a reply from the frozen marine_evidence_v3 Evidence Packet ALONE through this renderer, so the
# customer still receives the authoritative family price range without invoking the legacy path. It is
# scoped to EXACTLY the single response goal answer_price_range and the single fact key price_range; any
# other goal (an exact answer_price included) or fact is out of scope and yields nil so the presenter keeps
# that path's existing closed fallback.
#
# It is a standalone fail-closed safety component, so it validates the FULL real v3 price-range contract
# from the packet ALONE before rendering — never a partial display-only pseudo-packet. It mirrors the
# EvidencePacketBuilder v3 schema (PRICE_RANGE_FACT_KEYS / PRICE_RANGE_CANONICAL_KEYS / PRICE_RANGE_DISPLAY_KEYS,
# the price-display-v1 policy_version + catalog_price_range_repository source + UTC-ISO8601 checked_at),
# requires the authoritative canonical family identity / currency / endpoints / UOM, requires the validated
# marine_catalog product slot whose code the canonical family_code byte-matches, requires the price_range-only
# scenario provenance (intents exactly ["price_range"]), the packet customer_language, and the closed
# presentation_policy ({ tone, verbosity, range_followup_mode } with Checkpoint A enum values) — all by
# PRESENCE and SHAPE only, with NO repository / DB / RAG / provider / PriceDisplayFormatter recompute. A
# packet missing / malforming any of these fails closed to nil.
#
# Its only business-fact input for the reply text is the authoritative, formatter-validated DISPLAY block
# the EvidencePacketBuilder already reconstructed from the strict canonical min/max (currency, min, max, uom)
# plus the packet customer_language. It renders them through backend-owned price-display-v1 id/en templates
# so the authoritative identity / currency / endpoints / UOM are preserved byte-for-byte and NEVER
# recomputed, reformatted, or invented (the display currency symbol — Rp for canonical IDR — is read as-is
# and never compared byte-wise to the canonical currency). Equal endpoints render a single amount; a true
# range renders both endpoints. The range_followup_mode controls the output: ask_variant_code appends a
# generic variant-selection follow-up (never claiming a catalog was shown), standalone appends none. It
# never reads the Model 2 candidate, the raw customer request/history, a provider / RAG / repository / DB /
# authority / legacy PriceRangeReplyComposer / AssistantChatService, and never adds a variant-specific
# price, stock/quantity, warehouse/location, delivery/lead time, discount/promotion, comparison/history, or
# any qualitative product claim. The authoritative source / policy_version / checked_at are validated but
# NEVER surfaced in the customer text.
#
# It FAILS CLOSED (returns nil, never repairs) on a non-range, multi-goal, wrong-version, malformed,
# mutable (not deeply frozen), injected, or unsupported-language packet, and never raises. It is pure and
# safe for repeated calls.
class Marine::Backend::PriceRangeEvidenceRenderer
  EVIDENCE_VERSION = 'marine_evidence_v3'.freeze
  RANGE_GOAL = 'answer_price_range'.freeze
  # The price_range candidate intent the scenario provenance must carry (mirrors the ExecutionPolicy
  # price_range authorization — the top-level intents set a range packet is built from is exactly
  # ["price_range"]).
  RANGE_INTENT = 'price_range'.freeze
  SUPPORTED_LANGUAGES = %w[id en].freeze

  # The real v3 price-range fact contract, mirrored from EvidencePacketBuilder (closed-key, fail-closed).
  RANGE_FACT_KEYS = %i[canonical display policy_version source checked_at].freeze
  RANGE_CANONICAL_KEYS = %i[family_code currency min max uom].freeze
  RANGE_DISPLAY_KEYS = %i[currency min max uom].freeze
  RANGE_SOURCE = 'catalog_price_range_repository'.freeze
  RANGE_POLICY_VERSION = 'price-display-v1'.freeze
  SLOT_SOURCE = 'marine_catalog'.freeze

  # The closed presentation-policy contract (mirrors EvidencePacketBuilder / PresentationPolicyProjector):
  # EXACTLY these three keys, each a closed enum value. range_followup_mode controls the output.
  PRESENTATION_POLICY_KEYS = %i[tone verbosity range_followup_mode].freeze
  PRESENTATION_TONES = %w[professional casual formal].freeze
  PRESENTATION_VERBOSITIES = %w[concise detailed].freeze
  PRESENTATION_RANGE_FOLLOWUPS = %w[ask_variant_code standalone].freeze
  FOLLOWUP_ASK = 'ask_variant_code'.freeze

  # A finite, non-negative exact decimal shape consistent with the builder's canonical min/max (mirrors
  # EvidencePacketBuilder::RATE_STRING): Integer, finite non-negative BigDecimal, or exact decimal String.
  # A Float and an exponent-notation String are rejected (no exactness guarantee).
  DECIMAL_STRING = /\A\d+(?:\.\d+)?\z/
  # ISO8601 UTC instant ending in Z (mirrors EvidencePacketBuilder::UTC_ISO8601).
  UTC_ISO8601 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

  # The backend-owned price-display-v1 range templates (localized id/en), plus the ask_variant_code helper.
  RANGE_TEMPLATE_KEY = 'marine.catalog.price_range.range_available'.freeze
  SINGLE_TEMPLATE_KEY = 'marine.catalog.price_range.single_available'.freeze
  FOLLOWUP_TEMPLATE_KEY = 'marine.catalog.price_range.variant_followup'.freeze

  # packet: a frozen marine_evidence_v3 answer_price_range Evidence Packet.
  # Returns the deterministic range reply String, or nil on any non-range/malformed/unsupported outcome.
  def call(packet:)
    return nil unless renderable_packet?(packet)

    render(packet[:facts][:price_range], packet[:presentation_policy], packet[:customer_language])
  rescue StandardError
    nil
  end

  private

  # In scope ONLY for a DEEPLY FROZEN v3 packet whose sole response goal is answer_price_range, whose
  # scenario provenance is price_range-only, that carries a supported customer_language, whose facts carry
  # EXACTLY the price_range key holding the full real range fact bound to a validated marine_catalog product
  # slot, and whose closed presentation_policy is a valid enum triple.
  def renderable_packet?(packet) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent structural packet guards
    packet.is_a?(Hash) && deeply_frozen?(packet) &&
      packet[:evidence_version] == EVIDENCE_VERSION &&
      packet[:response_goals] == [RANGE_GOAL] &&
      range_only_provenance?(packet[:scenario]) &&
      SUPPORTED_LANGUAGES.include?(packet[:customer_language]) &&
      packet[:facts].is_a?(Hash) &&
      packet[:facts].keys == %i[price_range] &&
      valid_range_fact?(packet[:facts][:price_range], packet[:validated_slots]) &&
      valid_presentation_policy?(packet[:presentation_policy])
  end

  # The scenario provenance of a range turn carries EXACTLY the price_range candidate intent.
  def range_only_provenance?(scenario)
    scenario.is_a?(Hash) && scenario[:intents] == [RANGE_INTENT]
  end

  # The full real range fact: EXACTLY { canonical, display, policy_version, source, checked_at }, with the
  # authoritative canonical family identity/endpoints bound to the validated product slot, the approved
  # price-display-v1 policy, the catalog_price_range_repository provenance, a UTC-ISO8601 timestamp, and the
  # authoritative display block.
  def valid_range_fact?(fact, validated_slots)
    fact.is_a?(Hash) &&
      fact.keys.sort == RANGE_FACT_KEYS.sort &&
      valid_canonical?(fact[:canonical], validated_slots) &&
      valid_display?(fact[:display]) &&
      fact[:policy_version] == RANGE_POLICY_VERSION &&
      fact[:source] == RANGE_SOURCE &&
      valid_timestamp?(fact[:checked_at])
  end

  # The authoritative canonical facts: EXACTLY { family_code, currency, min, max, uom } — the family
  # identity/currency/uom are present control-free Strings, min/max exact non-negative decimals with
  # min <= max, and the family_code byte-matches the validated marine_catalog product slot.
  def valid_canonical?(canonical, validated_slots) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent canonical-fact guards
    canonical.is_a?(Hash) &&
      canonical.keys.sort == RANGE_CANONICAL_KEYS.sort &&
      safe_string?(canonical[:family_code]) &&
      safe_string?(canonical[:currency]) &&
      safe_string?(canonical[:uom]) &&
      valid_decimal?(canonical[:min]) && valid_decimal?(canonical[:max]) &&
      decimal(canonical[:min]) <= decimal(canonical[:max]) &&
      family_identity_matches?(canonical[:family_code], validated_slots)
  end

  # The packet must ground the range on a validated marine_catalog PRODUCT slot whose code the canonical
  # family_code byte-matches — so the authoritative identity the reply names is the resolved family, never
  # forged, and never a free-form product name.
  def family_identity_matches?(family_code, validated_slots)
    validated_slots.is_a?(Hash) &&
      (product = validated_slots[:product]).is_a?(Hash) &&
      product[:code] == family_code &&
      product[:source] == SLOT_SOURCE
  end

  # The authoritative display block is EXACTLY { currency, min, max, uom }, each a present, control-free
  # String. The display currency is the locale symbol (Rp for canonical IDR) and is intentionally NOT
  # required to equal the canonical currency; the renderer reads it as-is and never reformats/recomputes it.
  def valid_display?(display)
    display.is_a?(Hash) &&
      display.keys.sort == RANGE_DISPLAY_KEYS.sort &&
      RANGE_DISPLAY_KEYS.all? { |key| safe_string?(display[key]) }
  end

  # The closed v3 presentation-policy contract: EXACTLY { tone, verbosity, range_followup_mode }, each an
  # allowed enum member. An enum membership check inherently rejects any control-char/newline/injection value.
  def valid_presentation_policy?(policy)
    policy.is_a?(Hash) &&
      policy.keys.sort == PRESENTATION_POLICY_KEYS.sort &&
      PRESENTATION_TONES.include?(policy[:tone]) &&
      PRESENTATION_VERBOSITIES.include?(policy[:verbosity]) &&
      PRESENTATION_RANGE_FOLLOWUPS.include?(policy[:range_followup_mode])
  end

  def valid_decimal?(value)
    case value
    when Integer then !value.negative?
    when BigDecimal then value.finite? && !value.negative?
    when String then value.match?(DECIMAL_STRING)
    else false
    end
  end

  def decimal(value) = BigDecimal(value.to_s)

  def valid_timestamp?(value)
    value.is_a?(String) && value.match?(UTC_ISO8601)
  end

  def safe_string?(value)
    value.is_a?(String) && !value.strip.empty? && !value.match?(/[[:cntrl:]]/)
  end

  # Every nested container, key, and scalar must be frozen — a mutable or shallow-frozen pseudo-packet
  # fails closed (mirrors the presenter's deep-frozen gate).
  def deeply_frozen?(value)
    return false unless value.frozen?

    case value
    when Hash then value.all? { |key, child| key.frozen? && deeply_frozen?(child) }
    when Array then value.all? { |child| deeply_frozen?(child) }
    else true
    end
  end

  # The approved price-display-v1 range/single template in the packet language, built from the
  # authoritative family code + display facts ALONE. The family identity emitted is the canonical/validated
  # family code only. Equal endpoints render a single amount; a true range renders both. A missing locale
  # key (template or ask_variant_code follow-up helper) fails closed (never an invented sentence).
  def render(fact, policy, language)
    followup = followup_text(policy[:range_followup_mode], language)
    return nil if followup.nil?

    canonical = fact[:canonical]
    display = fact[:display]
    if decimal(canonical[:min]) == decimal(canonical[:max])
      translate(SINGLE_TEMPLATE_KEY, language, product: canonical[:family_code], currency: display[:currency],
                                               amount: display[:min], uom: display[:uom], followup: followup)
    else
      translate(RANGE_TEMPLATE_KEY, language, product: canonical[:family_code], currency: display[:currency],
                                              min: display[:min], max: display[:max], uom: display[:uom], followup: followup)
    end
  end

  # '' for standalone; the localized generic variant-selection follow-up for ask_variant_code; nil (fail
  # closed) when the ask_variant_code helper key is missing.
  def followup_text(mode, language)
    return '' unless mode == FOLLOWUP_ASK

    translate(FOLLOWUP_TEMPLATE_KEY, language)
  end

  def translate(key, language, **vars)
    text = I18n.t(key, locale: language, default: nil, **vars)
    return nil unless text.is_a?(String) && !text.strip.empty?

    text
  end
end
