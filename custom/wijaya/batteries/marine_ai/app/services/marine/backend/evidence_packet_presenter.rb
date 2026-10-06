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
# Fallback policy (A8-01 / no needless handoff): any ineligibility, generator failure, malformed
# output, or validator/verifier rejection returns a CLOSED reason plus the packet's safe fallback —
# :deterministic for a valid answer/clarification packet (whose verified facts/slots the existing
# deterministic renderer can safely present), reserving :handoff for an explicit handoff/factless
# or invalid packet. This is a result POLICY only; no fallback delivery is wired in 3A-1.
class Marine::Backend::EvidencePacketPresenter
  EVIDENCE_VERSION = 'marine_evidence_v2'.freeze

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

  def initialize(prompt_builder: nil, fact_validator: nil, persona_validator: nil)
    @prompt_builder = prompt_builder || Marine::Backend::EvidencePromptBuilder.new
    @fact_validator = fact_validator || Marine::Backend::PostGenerationFactValidator.new
    @persona_validator = persona_validator || Marine::Backend::PersonaValidator.new
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
  def call(packet:, generator:, customer_request:, message_history: [], fact_verifier: nil)
    return failure(:invalid_packet, fallback: :handoff) unless valid_packet?(packet)

    fallback = fallback_for(packet)
    return failure(:not_generatable, fallback: fallback) unless generatable?(packet)

    candidate = generate(generator, packet, customer_request, message_history)
    return failure(:generation_failed, fallback: fallback) if candidate.nil?

    reason = rejection_reason(packet, candidate, fact_verifier)
    return failure(reason, fallback: fallback) if reason

    Result.new(ok: true, text: candidate, reason: 'accepted', detail: nil, fallback: nil).freeze
  end

  private

  # A valid packet is a DEEPLY FROZEN, closed top-level Evidence Packet: exact required keys (only
  # customer_language optional), no unknown keys, expected container types, a closed non-empty
  # response-goal set, a valid generated_at, and recursively frozen containers/scalars. This is a
  # structural gate run BEFORE any generator invocation — not a permissive repair.
  def valid_packet?(packet) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent structural packet guards
    packet.is_a?(Hash) && packet.frozen? &&
      packet[:evidence_version] == EVIDENCE_VERSION &&
      closed_keys?(packet) &&
      packet[:generated_at].is_a?(String) && packet[:generated_at].match?(UTC_ISO8601) &&
      valid_goals?(packet[:response_goals]) &&
      containers_typed?(packet) &&
      deeply_frozen?(packet)
  end

  def closed_keys?(packet)
    keys = packet.keys
    (keys - (REQUIRED_KEYS + OPTIONAL_KEYS)).empty? && (REQUIRED_KEYS - keys).empty?
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

  # The closed rejection reason for an untrusted candidate, or nil when every gate accepts. The
  # deterministic fact + persona gates run first; EVERY generated answer then requires the injected
  # semantic verifier to confirm the reply's facts equal the packet's.
  def rejection_reason(packet, candidate, fact_verifier)
    return :fact_rejected unless @fact_validator.call(packet: packet, candidate: candidate).ok?
    return :persona_rejected unless @persona_validator.call(candidate: candidate).ok?
    return :fact_unverified unless semantically_verified?(fact_verifier, packet, candidate)

    nil
  end

  def generate(generator, packet, customer_request, message_history)
    return nil unless generator.respond_to?(:call)

    prompt = @prompt_builder.build(packet: packet, customer_request: customer_request, message_history: message_history)
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
