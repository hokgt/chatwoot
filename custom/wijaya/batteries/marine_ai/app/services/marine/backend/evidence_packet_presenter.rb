# Fase 3A-1 (isolated / mock-only) — presentation seam for the Model 2 GENERATED wording path.
#
# It accepts ONLY the frozen marine_evidence_v2 Evidence Packet plus an INJECTED generator
# interface (and an optional injected stock fact verifier) — it NEVER constructs or calls a live
# provider, so 3A-1 tests and (until a later gate) the runtime make zero model calls through it.
# Model 2 is used ONLY here, on the generated/natural path; the zero-model safe paths (exact FAQ
# Gate G, deterministic clarification/refusal/handoff, existing deterministic price/stock
# fallback) are untouched and never routed through this seam.
#
# Pipeline for a generatable packet: build a packet-only bounded prompt -> ask the injected
# generator -> run the deterministic PostGenerationFactValidator (exact code / immutable price /
# no unauthorized token / no structural or control leak) -> run the PersonaValidator (Marine role,
# no sales-team self-deflection, no non-Marine identity) -> require the injected semantic fact
# verifier to confirm the reply's facts are equivalent to the packet (binary stock not flipped, no
# unsupported verbal fact). The semantic verifier is REQUIRED for EVERY generated answer path
# (price / stock / product_overview) — a missing, erroring, or rejecting verifier fails closed.
# Only an all-accept candidate is returned.
#
# Step 17 exception (answer_product_listing ONLY): after the deterministic fact + persona gates pass,
# a semantic rejection/error/missing DISCARDS the candidate and renders a deterministic reply from the
# packet's product_listing Evidence (via ProductListingEvidenceRenderer), returned as an ok=true
# Result so the customer execution never invokes the legacy path. Every other goal — product_information
# included — keeps the closed :fact_unverified fallback below. Fact/persona failures stay closed for
# listing too.
#
# Step 18 / Checkpoint B / binary stock exception: for a renderable deterministic-fact packet EVERY
# candidate failure — generation failure, fact rejection, persona rejection, OR a semantic
# rejection/error/missing — DISCARDS the untrusted candidate and renders a deterministic reply from the
# packet's Evidence (via ExactPriceEvidenceRenderer for answer_price, PriceRangeEvidenceRenderer for
# answer_price_range, or BinaryStockEvidenceRenderer for answer_stock), returned ok=true so the customer
# execution never invokes the legacy path. This is broader than Step 17 (which only intercepts the
# semantic step) because each has an authoritative frozen Evidence to render at every failure. Each
# renderer is scoped to exactly its own goal+fact; product_information / overview / clarify keep their
# existing closed fallback.
#
# Fallback policy (A8-01 / no needless handoff): any ineligibility, generator failure, malformed
# output, or validator/verifier rejection returns a CLOSED reason plus the packet's safe fallback —
# :deterministic for a valid answer/clarification packet (whose verified facts/slots the existing
# deterministic renderer can safely present), reserving :handoff for an explicit handoff/factless
# or invalid packet. This is a result POLICY only; no fallback delivery is wired in 3A-1.
class Marine::Backend::EvidencePacketPresenter
  EVIDENCE_VERSION = 'marine_evidence_v2'.freeze
  # Checkpoint A — the staged v3 version (answer_price_range) carrying a presentation_policy. v3 is
  # accepted here; its policy is threaded into the Model 2 prompt as trusted control + into the fact
  # validator's leak guard. Every v2 goal (price/listing/stock/overview/clarify) is unchanged.
  EVIDENCE_VERSION_V3 = 'marine_evidence_v3'.freeze
  EVIDENCE_VERSIONS = [EVIDENCE_VERSION, EVIDENCE_VERSION_V3].freeze
  # The only extra top-level key a v3 packet may carry.
  V3_OPTIONAL_KEYS = %i[presentation_policy].freeze
  # The single response-goal set a v3 packet is restricted to, and the closed presentation-policy
  # contract (EXACT keys + enum values) this seam INDEPENDENTLY revalidates. Kept small and local
  # (mirrors EvidencePacketBuilder / PresentationPolicyProjector) — defense in depth so a malformed/crossed
  # v3 packet handed directly to the presenter returns :invalid_packet before any generator call.
  V3_GOALS = %w[answer_price_range].freeze
  PRESENTATION_POLICY_KEYS = %i[tone verbosity range_followup_mode].freeze
  PRESENTATION_TONES = %w[professional casual formal].freeze
  PRESENTATION_VERBOSITIES = %w[concise detailed].freeze
  PRESENTATION_RANGE_FOLLOWUPS = %w[ask_variant_code standalone].freeze

  # The packet answer goals that warrant a generated natural reply. clarify_* / handoff are
  # deterministic zero-model paths and are never generated here. The Phase-3 bounded-catalog answers
  # (answer_product_listing / answer_product_information) and the Phase-5 answer_price_range are
  # generated here too.
  ANSWER_GOALS = %w[answer_price answer_price_range answer_stock answer_product_overview
                    answer_product_listing answer_product_information].freeze
  # The answer goals that have an EXISTING deterministic renderer to fall back on. The Phase-3 listing
  # answers and the Phase-5 answer_price_range have none, so a generation failure there falls back to
  # :handoff rather than a renderer that cannot present it.
  DETERMINISTIC_ANSWER_GOALS = %w[answer_price answer_stock answer_product_overview].freeze
  # Clarification goals are still valid, presentable (deterministic) packets — just not generated.
  CLARIFY_GOALS = %w[clarify_product clarify_variant clarify_ambiguous_variant].freeze
  # The closed response-goal enum (answer + clarify + handoff), used by the structural packet gate.
  ALL_RESPONSE_GOALS = (ANSWER_GOALS + CLARIFY_GOALS + %w[handoff]).freeze

  # The exact builder top-level keys (customer_language is the only optional one) and a valid
  # generated_at shape. This is the structural packet contract the seam enforces as DEFENSE IN
  # DEPTH; EvidencePacketBuilder remains the full semantic validator.
  REQUIRED_KEYS = %i[evidence_version generated_at response_goals scenario validated_slots
                     facts missing_slots variant_candidates prohibited_claims response_constraints].freeze
  OPTIONAL_KEYS = %i[customer_language].freeze
  UTC_ISO8601 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

  Result = Struct.new(:ok, :text, :reason, :detail, :fallback, keyword_init: true) do
    def ok? = ok == true
  end

  def initialize(prompt_builder: nil, fact_validator: nil, persona_validator: nil, listing_renderer: nil, # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- injectable closed-path collaborators, each defaulting to its production instance
                 price_renderer: nil, price_range_renderer: nil, stock_renderer: nil, offerings_renderer: nil)
    @prompt_builder = prompt_builder || Marine::Backend::EvidencePromptBuilder.new
    @fact_validator = fact_validator || Marine::Backend::PostGenerationFactValidator.new
    @persona_validator = persona_validator || Marine::Backend::PersonaValidator.new
    @listing_renderer = listing_renderer || Marine::Backend::ProductListingEvidenceRenderer.new
    @price_renderer = price_renderer || Marine::Backend::ExactPriceEvidenceRenderer.new
    @price_range_renderer = price_range_renderer || Marine::Backend::PriceRangeEvidenceRenderer.new
    @stock_renderer = stock_renderer || Marine::Backend::BinaryStockEvidenceRenderer.new
    @offerings_renderer = offerings_renderer || Marine::Backend::CompanyOfferingsEvidenceRenderer.new
  end

  # packet:           a frozen marine_evidence_v2 Evidence Packet.
  # generator:        REQUIRED injected callable #call(system:, messages:) -> String | nil. The
  #                   ONLY model call; no live provider is constructed here.
  # customer_request: the customer's latest message.
  # message_history:  bounded prior canonical turns.
  # fact_verifier:    REQUIRED injected callable #call(packet:, candidate:) -> Boolean — the
  #                   independent semantic proof the reply's facts equal the packet's (an interface
  #                   only in 3A-1; no provider constructed/called here). Missing/error/false fails
  #                   closed for EVERY generated answer path.
  def call(packet:, generator:, customer_request:, message_history: [], fact_verifier: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent fail-closed generation/validation gates
    return failure(:invalid_packet, fallback: :handoff) unless valid_packet?(packet)

    fallback = fallback_for(packet)
    return failure(:not_generatable, fallback: fallback) unless generatable?(packet)

    prompt = build_prompt(packet, customer_request, message_history)
    return price_or_failure(packet, :generation_failed, fallback) if prompt.nil?

    candidate = generate(generator, prompt)
    return price_or_failure(packet, :generation_failed, fallback) if candidate.nil?

    # The deterministic fact + persona gates stay fail-closed. The fact validator additionally receives
    # the prompt's dynamic trusted-control text(s) (the v3 presentation-policy block; empty for v2) so a
    # verbatim copy of the control block is rejected. EVERY generated answer then requires the injected
    # semantic verifier; an accepted candidate is returned verbatim.
    return price_or_failure(packet, :fact_rejected, fallback) unless fact_validated?(packet, candidate, prompt)
    return price_or_failure(packet, :persona_rejected, fallback) unless @persona_validator.call(candidate: candidate).ok?
    return accepted(candidate) if semantically_verified?(fact_verifier, packet, candidate)

    # Step 17 — a listing semantic rejection/error/missing DISCARDS the untrusted candidate and renders
    # a deterministic reply from the packet's product_listing Evidence (returned ok=true), so the
    # customer execution never invokes the legacy path for this condition. The renderer is scoped to
    # answer_product_listing only; every other goal (product_information included) keeps the closed
    # :fact_unverified fallback.
    listing_text = @listing_renderer.call(packet: packet)
    return listing_fallback(listing_text) if listing_text

    price_or_failure(packet, :fact_unverified, fallback)
  end

  private

  def accepted(candidate)
    Result.new(ok: true, text: candidate, reason: 'accepted', detail: nil, fallback: nil).freeze
  end

  def listing_fallback(text)
    Result.new(ok: true, text: text, reason: 'listing_evidence_fallback', detail: nil, fallback: nil).freeze
  end

  # Step 18 / Checkpoint B / binary stock — for a renderable deterministic-fact packet, EVERY candidate
  # failure (generation / fact / persona / semantic) DISCARDS the untrusted candidate and renders a
  # deterministic reply from the packet's Evidence ALONE (returned ok=true), so the customer execution
  # never invokes the legacy path for this condition. The exact-price renderer (answer_price /
  # marine_evidence_v2 price fact) is tried FIRST; then the family price-RANGE renderer (answer_price_range
  # / marine_evidence_v3 price_range fact); then the binary stock renderer (answer_stock /
  # marine_evidence_v2 stock fact). Each is scoped to exactly its own goal+fact and yields nil otherwise,
  # so a non-renderable packet (product_information / overview / clarify) keeps its existing closed fallback
  # byte-for-byte and reaches the caller's legacy path.
  def price_or_failure(packet, reason, fallback)
    price_text = @price_renderer.call(packet: packet)
    return price_fallback(price_text, reason) if price_text

    range_text = @price_range_renderer.call(packet: packet)
    return price_range_fallback(range_text, reason) if range_text

    stock_text = @stock_renderer.call(packet: packet)
    return stock_fallback(stock_text, reason) if stock_text

    offerings_text = @offerings_renderer.call(packet: packet)
    return offerings_fallback(offerings_text, reason) if offerings_text

    failure(reason, fallback: fallback)
  end

  def offerings_fallback(text, origin)
    Result.new(ok: true, text: text, reason: 'company_offerings_evidence_fallback', detail: origin, fallback: nil).freeze
  end

  def price_fallback(text, origin)
    Result.new(ok: true, text: text, reason: 'price_evidence_fallback', detail: origin, fallback: nil).freeze
  end

  def price_range_fallback(text, origin)
    Result.new(ok: true, text: text, reason: 'price_range_evidence_fallback', detail: origin, fallback: nil).freeze
  end

  def stock_fallback(text, origin)
    Result.new(ok: true, text: text, reason: 'stock_evidence_fallback', detail: origin, fallback: nil).freeze
  end

  # A valid packet is a DEEPLY FROZEN, closed top-level Evidence Packet: exact required keys (only
  # customer_language optional), no unknown keys, expected container types, a closed non-empty
  # response-goal set, a valid generated_at, and recursively frozen containers/scalars. This is a
  # structural gate run BEFORE any generator invocation — not a permissive repair.
  def valid_packet?(packet) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent structural packet guards
    packet.is_a?(Hash) && packet.frozen? &&
      EVIDENCE_VERSIONS.include?(packet[:evidence_version]) &&
      closed_keys?(packet) &&
      packet[:generated_at].is_a?(String) && packet[:generated_at].match?(UTC_ISO8601) &&
      valid_goals?(packet[:response_goals]) &&
      containers_typed?(packet) &&
      deeply_frozen?(packet)
  end

  # A v2 packet carries exactly the required + customer_language keys and NO presentation_policy. A v3
  # packet additionally REQUIRES the presentation_policy key (the only extra), its goal set is EXACTLY
  # answer_price_range, and its policy is a closed { tone, verbosity, range_followup_mode } with exact enum
  # values — INDEPENDENTLY revalidated here (the EvidencePacketBuilder remains the full semantic validator,
  # but a direct caller must not be trusted). A malformed/missing/extra key, bad-enum/injection value, or a
  # crossed goal/version fails closed to :invalid_packet before any generator call.
  def closed_keys?(packet)
    keys = packet.keys
    return false unless (REQUIRED_KEYS - keys).empty?

    if packet[:evidence_version] == EVIDENCE_VERSION_V3
      (keys - (REQUIRED_KEYS + OPTIONAL_KEYS + V3_OPTIONAL_KEYS)).empty? &&
        packet[:response_goals] == V3_GOALS &&
        valid_presentation_policy?(packet[:presentation_policy])
    else
      (keys - (REQUIRED_KEYS + OPTIONAL_KEYS)).empty?
    end
  end

  # The closed v3 presentation-policy contract: EXACTLY { tone, verbosity, range_followup_mode }, each an
  # allowed enum member. An enum membership check inherently rejects any control-char/newline/injection
  # value.
  def valid_presentation_policy?(policy)
    policy.is_a?(Hash) &&
      policy.keys.sort == PRESENTATION_POLICY_KEYS.sort &&
      PRESENTATION_TONES.include?(policy[:tone]) &&
      PRESENTATION_VERBOSITIES.include?(policy[:verbosity]) &&
      PRESENTATION_RANGE_FOLLOWUPS.include?(policy[:range_followup_mode])
  end

  def valid_goals?(goals)
    goals.is_a?(Array) && !goals.empty? && goals.all? { |goal| ALL_RESPONSE_GOALS.include?(goal) }
  end

  def containers_typed?(packet)
    packet[:scenario].is_a?(Hash) && packet[:validated_slots].is_a?(Hash) &&
      packet[:facts].is_a?(Hash) && packet[:response_constraints].is_a?(Hash) &&
      packet[:missing_slots].is_a?(Array) && packet[:variant_candidates].is_a?(Array) &&
      packet[:prohibited_claims].is_a?(Array)
  end

  # Every nested container, key, and scalar must be frozen — a shallow-frozen packet (top frozen,
  # a nested container mutable) fails closed.
  def deeply_frozen?(value)
    return false unless value.frozen?

    case value
    when Hash then value.all? { |key, child| key.frozen? && deeply_frozen?(child) }
    when Array then value.all? { |child| deeply_frozen?(child) }
    else true
    end
  end

  def generatable?(packet)
    Array(packet[:response_goals]).intersect?(ANSWER_GOALS)
  end

  # A price/stock/overview answer or a clarification packet falls back to the existing deterministic
  # renderer; a listing answer with no deterministic renderer, and an explicit handoff/factless packet,
  # reserve :handoff.
  def fallback_for(packet)
    Array(packet[:response_goals]).intersect?(DETERMINISTIC_ANSWER_GOALS + CLARIFY_GOALS) ? :deterministic : :handoff
  end

  # The packet-only bounded prompt (system + messages + the dynamic control_texts for the leak guard).
  # Built once BEFORE generation so the exact control text(s) can be threaded to the fact validator. A
  # malformed-input/build failure fails closed to nil (the caller folds to the deterministic fallback).
  def build_prompt(packet, customer_request, message_history)
    @prompt_builder.build(packet: packet, customer_request: customer_request, message_history: message_history)
  rescue StandardError
    nil
  end

  # The deterministic fact gate, additionally handed the prompt's dynamic trusted-control text(s) (empty
  # for v2) so a verbatim copy of the v3 presentation-policy control block is rejected.
  def fact_validated?(packet, candidate, prompt)
    @fact_validator.call(packet: packet, candidate: candidate, control_texts: prompt[:control_texts]).ok?
  end

  def generate(generator, prompt)
    return nil unless generator.respond_to?(:call)

    raw = generator.call(system: prompt[:system], messages: prompt[:messages])
    return nil unless raw.is_a?(String)

    stripped = raw.strip
    stripped.empty? ? nil : stripped
  rescue StandardError
    nil
  end

  # The injected semantic verifier must exist and return exactly true; a missing, non-callable,
  # erroring, or non-true verifier fails closed.
  def semantically_verified?(fact_verifier, packet, candidate)
    return false unless fact_verifier.respond_to?(:call)

    fact_verifier.call(packet: packet, candidate: candidate) == true
  rescue StandardError
    false
  end

  def failure(reason, fallback:, detail: nil)
    Result.new(ok: false, text: nil, reason: reason, detail: detail, fallback: fallback).freeze
  end
end
