# Deterministic binary-stock Evidence renderer.
#
# When a Model 2 answer_stock candidate fails ANY acceptance gate — generation failure, the
# deterministic PostGenerationFactValidator, the PersonaValidator, or the semantic EvidenceFactVerifier
# (false / exception / missing / non-callable) — the presenter DISCARDS that untrusted candidate and
# renders a reply from the frozen marine_evidence_v2 Evidence Packet ALONE through this renderer, so the
# customer still receives the authoritative binary availability without invoking the legacy path. It is
# scoped to EXACTLY the single response goal answer_stock and the single fact key stock; any other goal or
# fact is out of scope and yields nil so the presenter keeps that path's existing closed fallback.
#
# It is a standalone fail-closed safety component, so it validates the FULL real stock contract from the
# packet ALONE before rendering. It mirrors the EvidencePacketBuilder stock schema (STOCK_FACT_KEYS /
# STOCK_STATUSES / the stock_repository source + UTC-ISO8601 checked_at) and requires the validated
# marine_catalog variant slot whose nonblank code the reply NAMES — all by PRESENCE and SHAPE only, with
# NO repository / DB / RAG / provider / formatter / history recompute. A binary stock fact carries no
# display/canonical/price block: the ONLY identity the reply surfaces is the validated variant code and
# the ONLY business fact is the available/unavailable status. A packet missing / malforming any of these
# fails closed to nil.
#
# It renders the status through the approved stock id/en templates (marine.catalog.stock.available /
# unavailable) built from the validated variant code ALONE. It never reads the Model 2 candidate, the raw
# customer request/history, a provider / RAG / repository / DB / authority / legacy composer, and never
# adds a stock quantity, warehouse/location, delivery/lead time, price/discount, comparison/history, or any
# qualitative product claim. The authoritative source / checked_at are validated but NEVER surfaced in the
# customer text.
#
# It FAILS CLOSED (returns nil, never repairs) on a non-stock, multi-goal, wrong-version, crossed-policy
# (a v3 presentation_policy on a v2 stock packet), malformed, injected, mutable (not deeply frozen), or
# unsupported-language packet, and never raises. It is pure and safe for repeated calls.
class Marine::Backend::BinaryStockEvidenceRenderer
  EVIDENCE_VERSION = 'marine_evidence_v2'.freeze
  STOCK_GOAL = 'answer_stock'.freeze
  # The stock candidate intent the scenario provenance must carry (mirrors the ExecutionPolicy stock
  # authorization — the top-level intents set a stock packet is built from is exactly ["stock"]).
  STOCK_INTENT = 'stock'.freeze
  SUPPORTED_LANGUAGES = %w[id en].freeze

  # The real stock fact contract, mirrored from EvidencePacketBuilder (closed-key, fail-closed).
  STOCK_FACT_KEYS = %i[status source checked_at].freeze
  STOCK_STATUSES = %w[available unavailable].freeze
  STOCK_SOURCE = 'stock_repository'.freeze
  SLOT_SOURCE = 'marine_catalog'.freeze

  # ISO8601 UTC instant ending in Z (mirrors EvidencePacketBuilder::UTC_ISO8601).
  UTC_ISO8601 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

  # The approved backend-owned stock templates (localized id/en), keyed by the binary status.
  TEMPLATE_KEYS = { 'available' => 'marine.catalog.stock.available',
                    'unavailable' => 'marine.catalog.stock.unavailable' }.freeze

  # packet: a frozen marine_evidence_v2 answer_stock Evidence Packet.
  # Returns the deterministic availability reply String, or nil on any non-stock/malformed/unsupported outcome.
  def call(packet:)
    return nil unless renderable_packet?(packet)

    render(packet[:facts][:stock][:status], packet[:validated_slots][:variant][:code], packet[:customer_language])
  rescue StandardError
    nil
  end

  private

  # In scope ONLY for a DEEPLY FROZEN v2 packet whose sole response goal is answer_stock, whose scenario
  # provenance is stock-only, that carries a supported customer_language, whose facts carry EXACTLY the
  # stock key holding the full real stock fact, and whose validated slots ground a marine_catalog variant.
  # A crossed packet that carries a v3 presentation_policy (never on a genuine v2 stock packet) fails closed.
  def renderable_packet?(packet) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent structural packet guards
    packet.is_a?(Hash) && deeply_frozen?(packet) &&
      packet[:evidence_version] == EVIDENCE_VERSION &&
      !packet.key?(:presentation_policy) &&
      packet[:response_goals] == [STOCK_GOAL] &&
      stock_only_provenance?(packet[:scenario]) &&
      SUPPORTED_LANGUAGES.include?(packet[:customer_language]) &&
      packet[:facts].is_a?(Hash) &&
      packet[:facts].keys == %i[stock] &&
      valid_stock_fact?(packet[:facts][:stock]) &&
      valid_variant_slot?(packet[:validated_slots])
  end

  # The scenario provenance of a stock turn carries EXACTLY the stock candidate intent.
  def stock_only_provenance?(scenario)
    scenario.is_a?(Hash) && scenario[:intents] == [STOCK_INTENT]
  end

  # The full real stock fact: EXACTLY { status, source, checked_at }, with a binary available/unavailable
  # status, the stock_repository provenance, and a UTC-ISO8601 timestamp. The status enum check inherently
  # rejects any control-char/blank status.
  def valid_stock_fact?(fact)
    fact.is_a?(Hash) &&
      fact.keys.sort == STOCK_FACT_KEYS.sort &&
      STOCK_STATUSES.include?(fact[:status]) &&
      fact[:source] == STOCK_SOURCE &&
      valid_timestamp?(fact[:checked_at])
  end

  # The packet must ground the binary stock on a validated marine_catalog VARIANT slot whose nonblank code
  # the reply names — so the identity surfaced is the resolved variant, never forged or a free-form name.
  def valid_variant_slot?(validated_slots)
    validated_slots.is_a?(Hash) &&
      (variant = validated_slots[:variant]).is_a?(Hash) &&
      safe_string?(variant[:code]) &&
      variant[:source] == SLOT_SOURCE
  end

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

  # The approved stock template for the binary status in the packet language, built from the validated
  # variant code ALONE. A missing / blank locale key fails closed (never an invented sentence).
  def render(status, code, language)
    text = I18n.t(TEMPLATE_KEYS.fetch(status), product: code, locale: language, default: nil)
    return nil unless text.is_a?(String) && !text.strip.empty?

    text
  end
end
