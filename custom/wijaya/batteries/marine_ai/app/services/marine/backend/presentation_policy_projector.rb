# Checkpoint A — the SINGLE customer-composition-root projection of the assistant's already-loaded
# configuration into a closed, deeply-frozen PRESENTATION POLICY: a small set of allowlisted
# tone / verbosity / range-followup control values the Model 2 wording path may be steered by.
#
# It is instantiated and called EXACTLY ONCE at the customer composition root
# (Marine::Backend::ExactPriceCustomerExecution) — NEVER from the EvidencePacketBuilder or a renderer —
# and reads ONLY the in-memory Marine::Assistant object (its loaded config instructions +
# response_guidelines jsonb attributes). It performs NO repository / DB / service / provider call.
#
# The output carries EXACTLY the three allowlisted keys, every key and value deeply frozen, and
# NEVER surfaces the raw instructions / guardrails / response_guidelines text or ANY business fact
# (price, product id, quantity, stock, warehouse, delivery) — its whole value space is a fixed enum
# triple. Unknown / blank / conflicting configuration deterministically resolves to a pinned value and
# NEVER raises. Downstream, factual/safety authority always dominates this advisory wording guidance:
# a policy can neither add nor change a fact.
class Marine::Backend::PresentationPolicyProjector
  TONE_VALUES = %w[professional casual formal].freeze
  VERBOSITY_VALUES = %w[concise detailed].freeze
  RANGE_FOLLOWUP_VALUES = %w[ask_variant_code standalone].freeze

  # The pinned fallback for every dimension — deeply frozen (hash + each value String).
  DEFAULTS = { tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code' }
             .each_value(&:freeze).freeze

  # Ordered tone rules — the FIRST whole-word, case-insensitive keyword that appears wins, so a
  # conflicting configuration ("be formal but casual") resolves deterministically. Precedence is
  # PINNED here (and in the specs): formal > casual > professional/polite; nothing matched =>
  # DEFAULTS[:tone]. Tone is driven by the assistant instructions ALONE.
  TONE_RULES = [%w[formal formal], %w[casual casual], %w[professional professional], %w[polite professional]].freeze

  # Ordered verbosity rules — detailed/lengkap take precedence over concise; nothing matched =>
  # DEFAULTS[:verbosity]. Precedence PINNED here (and in the specs). Verbosity is driven by the
  # assistant instructions + response_guidelines.
  VERBOSITY_RULES = [%w[detailed detailed], %w[lengkap detailed], %w[concise concise]].freeze

  def initialize(assistant:)
    @assistant = assistant
  end

  # The closed, deeply-frozen presentation policy. Never raises; unknown/blank/conflicting
  # configuration resolves to the pinned DEFAULTS. The assistant attributes are each read exactly once.
  def call
    instructions = read_instructions
    deep_freeze(
      tone: match(instructions.downcase, TONE_RULES, DEFAULTS[:tone]),
      verbosity: match([instructions, *read_response_guidelines].join(' ').downcase, VERBOSITY_RULES, DEFAULTS[:verbosity]),
      range_followup_mode: DEFAULTS[:range_followup_mode]
    )
  rescue StandardError
    DEFAULTS
  end

  private

  # Instructions ALONE drive tone. A non-assistant-shaped object (no config accessor) reads as blank.
  def read_instructions
    return '' unless @assistant.respond_to?(:config)

    @assistant.config.to_h['instructions'].to_s
  rescue StandardError
    ''
  end

  # Instructions + response_guidelines drive verbosity.
  def read_response_guidelines
    return [] unless @assistant.respond_to?(:response_guidelines)

    Array(@assistant.response_guidelines).map(&:to_s)
  rescue StandardError
    []
  end

  # The value of the first ordered rule whose whole-word keyword appears in the text, else the pinned
  # default. A fresh owned String so the returned policy can be independently deep-frozen.
  def match(text, rules, default)
    rules.each { |keyword, value| return value.dup if text.match?(/\b#{keyword}\b/) }
    default.dup
  end

  def deep_freeze(value)
    case value
    when Hash then value.each { |key, child| key.freeze and deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end
end
