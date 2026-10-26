# Strict, fail-closed normalizer for the battery-local Marine Decision Maker candidate
# plan (Phase 2 / Stage 1 — structure & normalization ONLY). Turns a FULLY UNTRUSTED
# parsed provider hash into the canonical, bounded, symbol-keyed candidate-plan v1
# shape, or raises Marine::Decision::Errors::InvalidCandidatePlan.
#
# ONE consistent boundary: any contract violation of a PRESENT value — a bad type, an
# unknown top-level or nested key, an unknown enum value, an out-of-bounds length or
# cardinality, a control character, a duplicate slot operation, or an incompatible
# clear/value shape — fails the WHOLE plan closed by raising. Only genuinely ABSENT
# optionals fall back to safe, narrower defaults (nil / empty / "low"). Authority is
# never silently broadened.
#
# This service does NOT call a provider, read Decision Maker settings, touch the runner
# or scenario selector, query the catalog/DB, mutate any state, or retain raw provider
# text / chain-of-thought. It only reshapes the given hash. The result is a CANDIDATE
# PLAN — a bounded suggestion — never backend authority: it can nominate a scenario,
# candidate product/variant strings, and intent categories, but never a validated fact
# (validated_variant_code, family, price, stock, quantity, warehouse), a final action,
# reply text, a tool, or SQL. Those arrive only as unknown keys and are rejected.
#
# The input hash is treated as read-only and is never mutated; a fresh structure is
# returned. Freezing/immutability is applied by Marine::Decision::CandidatePlan.
class Marine::Decision::Normalizer
  Schema = Marine::Decision::Schema

  def self.call(raw)
    new.call(raw)
  end

  # Returns a plain (unfrozen) canonical plan Hash with symbol keys, or raises
  # Marine::Decision::Errors::InvalidCandidatePlan. CandidatePlan.normalize deep-freezes it.
  def call(raw)
    raise invalid unless raw.is_a?(Hash)

    reject_unknown_keys!(raw, Schema::TOP_LEVEL_KEYS)
    validate_schema_version!(raw)

    {
      schema_version: Schema::SCHEMA_VERSION,
      scenario_candidate: scenario_candidate(fetch(raw, 'scenario_candidate')),
      intents: intents(fetch(raw, 'intents')),
      slot_operations: slot_operations(fetch(raw, 'slot_operations')),
      customer_language: customer_language(fetch(raw, 'customer_language')),
      confidence: confidence(fetch(raw, 'confidence')),
      # Normalizer-owned outcome code; any provider-supplied `reason` is ignored.
      reason: Schema::REASON_NORMALIZED
    }
  end

  private

  def validate_schema_version!(raw)
    raise invalid unless fetch(raw, 'schema_version') == Schema::SCHEMA_VERSION
  end

  def scenario_candidate(value)
    return { key: nil, confidence: 'low' } if value.nil?
    raise invalid unless value.is_a?(Hash)

    reject_unknown_keys!(value, Schema::SCENARIO_KEYS)
    {
      key: scenario_key(fetch(value, 'key')),
      confidence: confidence(fetch(value, 'confidence'))
    }
  end

  # Optional canonical scenario key. Absent or blank -> nil. A present, nonblank value must
  # ALREADY be canonical lowercase snake_case matching Schema::SCENARIO_KEY_PATTERN;
  # uppercase, hyphen, whitespace, and punctuation forms fail closed (never transformed).
  # Returns a fresh, caller-independent string so deep-freeze never touches caller memory.
  def scenario_key(value)
    return nil if value.nil?
    raise invalid unless value.is_a?(String)
    return nil if value.strip.empty?
    raise invalid unless value.match?(Schema::SCENARIO_KEY_PATTERN)

    value.dup
  end

  # Bounded, deduped, canonically ordered candidate intents. Canonical order and dedupe
  # both come from selecting against Schema::INTENTS, so ["stock","price"] and
  # ["price","stock","price"] both fold to ["price","stock"].
  def intents(value)
    return [] if value.nil?
    raise invalid unless value.is_a?(Array)
    raise invalid if value.length > Schema::MAX_RAW_ARRAY

    canonical_intents(value.map { |item| enum(item, Schema::INTENTS) })
  end

  # Dedupe + canonically order against Schema::INTENTS, then return FRESH owned copies so
  # deep-freeze never freezes the shared Schema::INTENTS constant strings.
  def canonical_intents(normalized)
    deduped = Schema::INTENTS.select { |code| normalized.include?(code) }
    raise invalid if deduped.length > Schema::MAX_INTENTS

    deduped.map(&:dup)
  end

  # Bounded candidate slot operations. Duplicate operations on the SAME slot fail closed;
  # the surviving operations are ordered by Schema::SLOTS for determinism.
  def slot_operations(value)
    return [] if value.nil?
    raise invalid unless value.is_a?(Array)
    raise invalid if value.length > Schema::MAX_RAW_ARRAY

    ops = value.map { |item| slot_operation(item) }
    reject_duplicate_slots!(ops)
    ops.sort_by { |operation| Schema::SLOTS.index(operation[:slot]) }
  end

  def reject_duplicate_slots!(ops)
    # Core-Ruby map (not ActiveSupport's Array#pluck) keeps this contract pure data.
    slots = ops.map { |operation| operation[:slot] } # rubocop:disable Rails/Pluck
    raise invalid if slots.uniq.length != slots.length
  end

  def slot_operation(value)
    raise invalid unless value.is_a?(Hash)

    reject_unknown_keys!(value, Schema::SLOT_OPERATION_KEYS)
    operation = enum(fetch(value, 'operation'), Schema::SLOT_OPERATIONS)
    slot = enum(fetch(value, 'slot'), Schema::SLOTS)
    { operation: operation, slot: slot, value: slot_value(operation, slot, fetch(value, 'value')) }
  end

  # `clear` forbids a value; `set`/`replace` require a valid candidate value object.
  def slot_value(operation, slot, value)
    if operation == 'clear'
      raise invalid unless value.nil?

      return nil
    end

    raise invalid unless value.is_a?(Hash)

    reject_unknown_keys!(value, Schema::VALUE_KEYS)
    {
      raw_candidate: bounded_candidate(fetch(value, 'raw_candidate'), Schema::MAX_RAW_CANDIDATE_LENGTH, required: true),
      candidate_type: enum(fetch(value, 'candidate_type'), Schema::CANDIDATE_TYPES.fetch(slot))
    }
  end

  def customer_language(value)
    return nil if value.nil?
    raise invalid unless value.is_a?(String)
    raise invalid if control_chars?(value)

    code = value.strip.downcase
    return nil if code.empty?
    raise invalid unless code.match?(Schema::LANGUAGE_PATTERN)

    code
  end

  # Absent -> safe "low" default; present-but-invalid -> fail closed.
  def confidence(value)
    return 'low' if value.nil?

    enum(value, Schema::CONFIDENCE_LEVELS)
  end

  # A bounded, control-char-free candidate string (case preserved), or nil for a
  # blank/absent value. A required blank/absent value fails closed.
  def bounded_candidate(value, limit, required:)
    candidate = clean_candidate(value, limit)
    raise invalid if candidate.nil? && required

    candidate
  end

  def clean_candidate(value, limit)
    return nil if value.nil?
    raise invalid unless value.is_a?(String)
    raise invalid if control_chars?(value)

    stripped = value.strip
    return nil if stripped.empty?
    raise invalid if stripped.length > limit

    stripped
  end

  def enum(value, allowed)
    raise invalid unless value.is_a?(String)

    code = value.strip.downcase
    raise invalid unless allowed.include?(code)

    code
  end

  # Reject any key outside the allowlist AND any hash that carries both the String and
  # Symbol form of the same key (e.g. 'key' and :key). Colliding forms fail closed so a
  # duplicate can never let one form shadow the other past the boundary.
  def reject_unknown_keys!(hash, allowed)
    stringified = hash.keys.map(&:to_s)
    raise invalid unless (stringified - allowed).empty?
    raise invalid if stringified.uniq.length != stringified.length
  end

  # Read a key tolerating either String or Symbol keys (parsed JSON vs Ruby input).
  def fetch(hash, key)
    return hash[key] if hash.key?(key)

    hash[key.to_sym]
  end

  def control_chars?(value)
    value.match?(/[[:cntrl:]]/)
  end

  def invalid
    Marine::Decision::Errors::InvalidCandidatePlan.new
  end
end
