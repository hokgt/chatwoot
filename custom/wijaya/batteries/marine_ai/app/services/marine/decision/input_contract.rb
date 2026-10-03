# Strict, bounded, fail-closed input contract for the battery-local Marine Decision
# Runner (Phase 2 / Stage 3 — ISOLATED, UNWIRED). It turns the caller's four raw inputs
# (latest customer message, recent context, coarse candidate state, and the enabled
# scenario/capability seam) into a single OWNED, bounded, string-keyed structure the
# request builder can serialize for either protocol.
#
# Trust boundary: everything here is UNTRUSTED caller input. Any violation of a present
# value — a bad type, an unknown/mixed/duplicate key or role, an out-of-bounds length,
# control-heavy text, an unknown capability/scenario-key form, a duplicate scenario key,
# or an empty scenario list — fails the WHOLE build closed by raising Invalid. Nothing is
# silently truncated. State is a candidate-only COARSE-HINT allowlist: it can never carry
# a price, stock, quantity, validated fact, ID, DB row, or arbitrary metadata.
#
# This file performs NO provider call, settings read, DB/catalog access, ScenarioSelector
# use, or state mutation. It DEEP-COPIES every outbound value into fresh, contract-owned
# objects and never mutates or freezes the caller's input.
class Marine::Decision::InputContract
  Schema = Marine::Decision::Schema

  # Raised on any contract violation. Carries a fixed message only — never the offending
  # value — so no untrusted content rides out. The runner folds it to a safe unknown plan.
  class Invalid < StandardError
    def initialize(message = 'decision runner input violated the contract')
      super
    end
  end

  ROLES = %w[user assistant].freeze

  # Coarse candidate-only state hints. Deliberately NO price/stock/quantity/validated
  # fact/ID/row/metadata key exists here — the allowlist is the whole guarantee.
  STATE_KEYS = %w[current_scenario current_intent awaiting_slot current_product_candidate current_variant_candidate].freeze
  CONTEXT_ENTRY_KEYS = %w[role content].freeze
  SCENARIO_ENTRY_KEYS = %w[key description instruction capabilities].freeze

  # Conservative bounds. Text bounds stay within the Decisions transport's own per-string
  # ceiling (2000) so one contract serves both protocols.
  MAX_MESSAGE_CHARS = 2_000
  MAX_MESSAGE_BYTES = 8_000
  MAX_CONTEXT_ENTRIES = 10
  MAX_CONTENT_CHARS = 2_000
  MAX_CONTENT_BYTES = 8_000
  MAX_CANDIDATE_CHARS = Schema::MAX_RAW_CANDIDATE_LENGTH
  MAX_SCENARIOS = 20
  MAX_SUMMARY_CHARS = 500
  MAX_SUMMARY_BYTES = 2_000
  MAX_CAPABILITIES = Schema::INTENTS.length

  # 'unsupported' is ALWAYS a permitted candidate intent (item 7: intents are intersected
  # with the union of declared capabilities PLUS unsupported), so a scenario set can never
  # forbid the runner from surfacing "no supported capability".
  ALWAYS_ALLOWED_INTENT = 'unsupported'.freeze

  def self.build(message:, context:, state:, scenarios:)
    new.build(message: message, context: context, state: state, scenarios: scenarios)
  end

  # Returns an owned, symbol-keyed contract Hash, or raises Invalid. The caller's input is
  # never mutated or frozen.
  def build(message:, context:, state:, scenarios:)
    scenario_list = scenarios(scenarios)
    {
      message: message(message),
      context: context(context),
      state: state(state),
      scenarios: scenario_list,
      scenario_keys: scenario_keys(scenario_list),
      allowed_intents: allowed_intents(scenario_list)
    }
  end

  private

  # Latest customer turn: a non-blank, sensibly-bounded, control-clean String. An oversized
  # or control-heavy value is REJECTED (not truncated) so an ambiguous huge blob never rides
  # in as a silently-clipped turn.
  def message(value)
    bounded_text!(value, MAX_MESSAGE_CHARS, MAX_MESSAGE_BYTES)
  end

  def context(value)
    return [] if value.nil?
    raise Invalid unless value.is_a?(Array)
    raise Invalid if value.length > MAX_CONTEXT_ENTRIES

    value.map { |entry| context_entry(entry) }
  end

  def context_entry(entry)
    attrs = exact_hash(entry, CONTEXT_ENTRY_KEYS)
    role = attrs['role']
    raise Invalid unless role.is_a?(String) && ROLES.include?(role)

    { role: role.dup, content: bounded_text!(attrs['content'], MAX_CONTENT_CHARS, MAX_CONTENT_BYTES) }
  end

  # Coarse candidate hints only. A key outside STATE_KEYS fails closed; a present value must
  # satisfy its per-key rule; a blank value is dropped (omitted), never guessed.
  def state(value)
    return {} if value.nil?

    attrs = exact_hash(value, STATE_KEYS)
    hints = {}
    put(hints, 'current_scenario', scenario_key_hint(attrs['current_scenario']))
    put(hints, 'current_intent', enum_hint(attrs['current_intent'], Schema::INTENTS))
    put(hints, 'awaiting_slot', enum_hint(attrs['awaiting_slot'], Schema::SLOTS))
    put(hints, 'current_product_candidate', candidate_hint(attrs['current_product_candidate']))
    put(hints, 'current_variant_candidate', candidate_hint(attrs['current_variant_candidate']))
    hints
  end

  def scenarios(value)
    raise Invalid unless value.is_a?(Array)
    raise Invalid unless value.length.between?(1, MAX_SCENARIOS)

    list = value.map { |entry| scenario_entry(entry) }
    # Core-Ruby map (not ActiveSupport's Array#pluck) keeps this contract pure data.
    keys = list.map { |scenario| scenario[:key] } # rubocop:disable Rails/Pluck
    raise Invalid if keys.uniq.length != keys.length # duplicate scenario keys fail closed

    list
  end

  def scenario_entry(entry)
    attrs = exact_hash(entry, SCENARIO_ENTRY_KEYS)
    {
      key: scenario_key!(attrs['key']),
      description: summary!(attrs['description']),
      instruction: summary!(attrs['instruction']),
      capabilities: capabilities(attrs['capabilities'])
    }
  end

  # Capabilities are candidate CONSTRAINTS, never inferred from title/token overlap: an
  # explicit, deduped, canonically-ordered subset of Schema::INTENTS.
  def capabilities(value)
    return [] if value.nil?
    raise Invalid unless value.is_a?(Array)
    raise Invalid if value.length > MAX_CAPABILITIES

    codes = value.map { |code| enum!(code, Schema::INTENTS) }
    raise Invalid if codes.uniq.length != codes.length

    Schema::INTENTS.select { |intent| codes.include?(intent) }
  end

  def scenario_keys(list)
    list.map { |scenario| scenario[:key].dup }
  end

  # Candidate intents the runner may ever propose: the UNION of every scenario's declared
  # capabilities plus 'unsupported', in canonical Schema order.
  def allowed_intents(list)
    union = list.flat_map { |scenario| scenario[:capabilities] } + [ALWAYS_ALLOWED_INTENT]
    Schema::INTENTS.select { |intent| union.include?(intent) }
  end

  def scenario_key!(value)
    raise Invalid unless value.is_a?(String) && value.match?(Schema::SCENARIO_KEY_PATTERN)

    value.dup
  end

  # Optional coarse scenario hint: blank -> nil; a present value must already be a canonical
  # scenario key (never transformed).
  def scenario_key_hint(value)
    return nil if value.nil?
    raise Invalid unless value.is_a?(String)
    return nil if value.strip.empty?
    raise Invalid unless value.match?(Schema::SCENARIO_KEY_PATTERN)

    value.dup
  end

  def enum_hint(value, allowed)
    return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

    enum!(value, allowed)
  end

  def candidate_hint(value)
    return nil if value.nil?
    raise Invalid unless value.is_a?(String) && value.valid_encoding?

    text = value.strip
    return nil if text.empty?
    raise Invalid if text.length > MAX_CANDIDATE_CHARS || control_heavy?(text)

    text.dup
  end

  def summary!(value)
    bounded_text!(value, MAX_SUMMARY_CHARS, MAX_SUMMARY_BYTES)
  end

  # Shared gate for a non-blank, bounded, control-clean String. Rejects (never truncates) a
  # wrong-type/blank/oversized/control-heavy value; returns a fresh owned copy.
  def bounded_text!(value, max_chars, max_bytes)
    raise Invalid unless value.is_a?(String) && value.valid_encoding?

    text = value.strip
    raise Invalid if text.empty? || text.length > max_chars || text.bytesize > max_bytes || control_heavy?(text)

    text.dup
  end

  def enum!(value, allowed)
    raise Invalid unless value.is_a?(String)

    code = value.strip.downcase
    raise Invalid unless allowed.include?(code)

    code.dup
  end

  # Reject any key outside the allowlist, and any hash carrying both the String and Symbol
  # form of the same key. Returns a fresh String-keyed hash so downstream reads are uniform.
  # Any key that is not itself a String or Symbol (a numeric key, or a malicious object with
  # a custom #to_s) is rejected BEFORE canonicalization, so #to_s can never manufacture an
  # allowlisted key from a hostile object.
  def exact_hash(value, allowed)
    raise Invalid unless value.is_a?(Hash) && stringy_keys?(value)

    stringified = value.keys.map(&:to_s)
    raise Invalid unless (stringified - allowed).empty?
    raise Invalid if stringified.uniq.length != stringified.length

    value.transform_keys(&:to_s)
  end

  # Every key must itself be a String or Symbol; a numeric or arbitrary-object key is rejected
  # before #to_s can manufacture an allowlisted key from a hostile object.
  def stringy_keys?(hash)
    hash.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
  end

  def put(hash, key, value)
    hash[key] = value unless value.nil?
  end

  # Control-heavy = any control character other than tab/newline/carriage-return (which are
  # legitimate in a customer turn). Rejects, never strips.
  def control_heavy?(text)
    text.match?(/[^\P{Cc}\t\n\r]/)
  end
end
