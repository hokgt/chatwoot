# Fase 3A-1 (isolated / mock-only) — deterministic post-generation fact gate for the Model 2
# generated wording path. It judges an UNTRUSTED generated candidate against the frozen
# marine_evidence_v2 Evidence Packet ONLY (no live provider, no DB). It proves, by
# construction, that the candidate:
#   * carries the exact validated variant code unchanged (required literal presence);
#   * carries the immutable price display amount / currency / UOM unchanged when a price fact
#     exists (required literal presence) — a changed amount/currency/UOM fails closed;
#   * introduces NO numeric, currency-symbol, or alphanumeric identifier token the packet does
#     not authorize — so an injected exact quantity, warehouse code, delivery date, discount,
#     changed price, or changed/added code is rejected;
#   * leaks no packet STRUCTURE (fenced or whole-JSON output, or any internal packet structural
#     key), and no control-INSTRUCTION wording (a long verbatim run of the Model 2 system
#     instruction), reusing Marine::Charge::ControlLeakInspector rather than a weaker duplicate.
#
# It contains NO product names, language wordlists, or customer phrases — only generic token
# classes, the packet's own values, and the internal structural key/instruction vocabulary. The
# BINARY stock outcome (not-flipped) plus every broader factual-equivalence check is a SEMANTIC
# judgement the presenter delegates to an injected verifier; this deterministic gate guards
# the identity and every numeric/code fact around it. It never raises or repairs: any failure
# or uncertainty returns a closed rejection so the caller delivers a deterministic fallback.
#
# ControlLeakInspector is a purely local, model-free overlap check — no live provider is
# referenced or constructed here.
class Marine::Backend::PostGenerationFactValidator
  UNSAFE_CONTROL_CHARS = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

  # A generated reply is at most a couple of short paragraphs; anything larger is malformed and
  # fails closed (well under the 16 KiB packet ceiling).
  MAX_CANDIDATE_BYTES = 2000
  # A bounded product-listing reply enumerates up to a full page of products (optionally with short
  # descriptions), so it is allowed a larger ceiling — still well under the 16 KiB packet ceiling.
  MAX_LISTING_CANDIDATE_BYTES = 8000

  # Generic token classes. NUMERIC and identifier/currency tokens in the candidate must be a
  # SUBSET of the packet-authorized inventory (free prose varies, so this is subset — not the
  # multiset equality the deterministic-fallback path uses).
  NUMERIC = /\d+(?:[.,]\d+)*/
  CURRENCY_SYMBOL = /\p{Sc}/
  # Alphanumeric runs carrying BOTH a letter and a digit — code-like identifiers that must not
  # change or be introduced.
  ALNUM_RUN = /[[:alnum:]]+/

  # EVERY internal packet structural key + the closed enum/version/source/policy identifiers a
  # natural customer reply must never surface (a packet-structure leak). Only snake_case internal
  # identifiers and the marine_* enums are listed — never a common domain word (price, stock,
  # product, code, amount, currency, …) that a legitimate reply may contain.
  LEAK_MARKERS = %w[
    evidence_version marine_evidence_v1 marine_evidence_v2 generated_at response_goals response_constraints
    prohibited_claims validated_slots missing_slots variant_candidates customer_language
    policy_version price_list_rate checked_at resolution_status item_group max_paragraphs
    handoff_self_reference marine_sales_assistant catalog_price_repository stock_repository
    price-display-v1 capabilities canonical
    product_listing returned_count total_count catalog_listing_repository
  ].freeze

  # The Model 2 control instruction whose wording a reply must never copy back verbatim. Reused as
  # the ControlLeakInspector control text (local overlap check only — no live provider).
  CONTROL_TEXTS = [Marine::Backend::EvidencePromptBuilder::SYSTEM_INSTRUCTION].freeze

  Result = Struct.new(:ok, :reason, keyword_init: true) do
    def ok? = ok == true
  end

  def initialize(control_leak_inspector: nil)
    @control_leak_inspector = control_leak_inspector || Marine::Charge::ControlLeakInspector.new
  end

  # packet:    a frozen marine_evidence_v2 Evidence Packet.
  # candidate: the untrusted generated reply text.
  def call(packet:, candidate:) # rubocop:disable Metrics/CyclomaticComplexity -- a flat sequence of independent fail-closed gates
    return reject(:malformed_candidate) unless valid_text?(candidate, max_candidate_bytes(packet))
    return reject(:packet_leak) if leaks_packet?(candidate)
    return reject(:control_leak) if leaks_control_instruction?(candidate)
    return reject(:missing_required_value) unless required_values(packet).all? { |value| present_as_literal?(candidate, value) }
    return reject(:unauthorized_token) unless tokens_within_inventory?(packet, candidate)

    Result.new(ok: true, reason: nil).freeze
  rescue StandardError
    reject(:error)
  end

  private

  # The byte ceiling depends on the packet: a bounded product listing may enumerate a full page, so it
  # is allowed MAX_LISTING_CANDIDATE_BYTES; every other reply stays at the short MAX_CANDIDATE_BYTES.
  def max_candidate_bytes(packet)
    dig(packet, :facts, :product_listing).is_a?(Hash) ? MAX_LISTING_CANDIDATE_BYTES : MAX_CANDIDATE_BYTES
  end

  def valid_text?(text, max_bytes)
    return false unless text.is_a?(String) && text.valid_encoding?

    stripped = text.strip
    return false if stripped.empty?
    return false if text.bytesize > max_bytes
    return false if text.match?(UNSAFE_CONTROL_CHARS)
    return false if stripped.start_with?('```')

    !whole_json_structure?(stripped)
  end

  def whole_json_structure?(stripped)
    return false unless ['{', '['].include?(stripped[0])

    parsed = JSON.parse(stripped)
    parsed.is_a?(Hash) || parsed.is_a?(Array)
  rescue JSON::ParserError
    false
  end

  def leaks_packet?(candidate)
    LEAK_MARKERS.any? { |marker| candidate.include?(marker) }
  end

  # A long verbatim run of the Model 2 control instruction reappearing in the reply is a control
  # leak (delegated to the shared local ControlLeakInspector — no live provider).
  def leaks_control_instruction?(candidate)
    @control_leak_inspector.leak?(reply: candidate, control_texts: CONTROL_TEXTS)
  end

  # Values that MUST appear unchanged: the validated variant code, and (when a price fact
  # exists) the immutable display amount / currency / UOM. Blank/absent values are skipped.
  def required_values(packet)
    values = []
    values << dig(packet, :validated_slots, :product, :code)
    values << dig(packet, :validated_slots, :variant, :code)
    price = dig(packet, :facts, :price)
    if price.is_a?(Hash)
      display = price[:display] || {}
      values.push(display[:amount], display[:currency], display[:uom])
    end
    values.concat(listing_required_values(dig(packet, :facts, :product_listing)))
    values.compact.uniq
  end

  # For a product listing, EVERY authorized product's code AND its display name (when present) MUST
  # appear literally — so an omitted product (missing code/name) or a renamed product (changed name)
  # fails closed. When the page is NOT complete, the EXACT bounded-coverage counts (returned_count and,
  # when the packet carries it, total_count) must also appear literally, so an incomplete page can
  # never be presented as the whole catalogue with a silently-dropped or mutated count.
  def listing_required_values(listing)
    return [] unless listing.is_a?(Hash)

    values = Array(listing[:products]).flat_map { |product| [product[:code], product[:name]] }
    unless listing[:complete] == true
      values << listing[:returned_count]&.to_s
      values << listing[:total_count]&.to_s
    end
    values
  end

  # Unicode-aware literal presence with alphanumeric boundaries, so a short code is not treated
  # as present merely because it appears inside a larger token.
  def present_as_literal?(text, value)
    text.match?(/(?<![[:alnum:]])#{Regexp.escape(value)}(?![[:alnum:]])/)
  end

  # Every numeric, currency-symbol, and code-like identifier token in the candidate must be
  # authorized by the packet's inventory.
  def tokens_within_inventory?(packet, candidate)
    allowed = inventory_source(packet)
    (candidate.scan(NUMERIC) - allowed.scan(NUMERIC)).empty? &&
      (candidate.scan(CURRENCY_SYMBOL) - allowed.scan(CURRENCY_SYMBOL)).empty? &&
      (identifier_tokens(candidate) - identifier_tokens(allowed)).empty?
  end

  # The concatenation of every packet value the reply may legitimately echo: the validated
  # slot codes and, when present, the price canonical + display facts.
  def inventory_source(packet) # rubocop:disable Metrics/AbcSize -- a flat concatenation of the packet's echoable slot/price/listing values
    parts = []
    parts << dig(packet, :validated_slots, :product, :code)
    parts << dig(packet, :validated_slots, :variant, :code)
    price = dig(packet, :facts, :price)
    if price.is_a?(Hash)
      canonical = price[:canonical] || {}
      display = price[:display] || {}
      parts.push(canonical[:variant_code], canonical[:currency], canonical[:price_list_rate], canonical[:uom],
                 display[:product], display[:currency], display[:amount], display[:uom])
    end
    listing = dig(packet, :facts, :product_listing)
    if listing.is_a?(Hash)
      Array(listing[:products]).each { |product| parts.push(product[:code], product[:name], product[:description]) }
      parts.push(listing[:returned_count], listing[:total_count])
    end
    parts.compact.map(&:to_s).join(' ')
  end

  def identifier_tokens(text)
    text.scan(ALNUM_RUN).select { |token| token.match?(/[[:alpha:]]/) && token.match?(/\d/) }.sort
  end

  def dig(hash, *keys)
    keys.reduce(hash) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
  end

  def reject(reason)
    Result.new(ok: false, reason: reason).freeze
  end
end
