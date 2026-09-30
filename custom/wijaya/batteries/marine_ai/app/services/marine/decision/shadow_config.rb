require 'json'

# DEFAULT-OFF, strictly READ-ONLY shadow configuration for the battery-local Marine
# Decision Maker shadow execution (Phase 2 / Stage 4 — shadow-only). It reads ONLY two
# InstallationConfig keys and NEVER writes, raises, logs, or touches Redis/DB beyond a
# plain read:
#
#   MARINE_DECISION_SHADOW_ENABLED         — off unless the stored value is the exact safe
#                                            true representation ('true'); anything else
#                                            (blank, 'false', '1', 'TRUE', arbitrary text)
#                                            is OFF.
#   MARINE_DECISION_SCENARIO_CAPABILITIES  — a bounded JSON object mapping stable
#                                            `scenario_<database id>` keys to arrays of
#                                            allowlisted Marine::Decision::Schema::INTENTS.
#
# The capability config is a candidate CONSTRAINT registry consumed by the ScenarioAdapter;
# it never carries a validated fact or action. It fails CLOSED to NO capabilities ({}) on
# ANY anomaly — malformed/oversize JSON, a non-object root, an out-of-bounds size, an
# unknown/mixed value type, an unknown intent, a duplicate intent, or a key that is not a
# canonical `scenario_<id>` — and never partially trusts a suspect config. It performs no
# write, enqueues nothing, and is not consulted by any UI/controller/settings-write path.
module Marine::Decision::ShadowConfig
  Schema = Marine::Decision::Schema

  ENABLED_KEY = 'MARINE_DECISION_SHADOW_ENABLED'.freeze
  CAPABILITIES_KEY = 'MARINE_DECISION_SCENARIO_CAPABILITIES'.freeze

  # The ONLY stored value that turns the shadow on. `InstallationConfig#value.to_s` renders
  # both a string "true" and a boolean true as "true", so this covers the safe true forms.
  ENABLED_TRUE = 'true'.freeze

  # Stable scenario-key format the ScenarioAdapter emits: `scenario_<database id>`. A bounded
  # digit run comfortably covers a bigint while keeping a hostile key small.
  SCENARIO_KEY_PATTERN = /\Ascenario_\d{1,19}\z/

  # Capabilities are a subset of the candidate intents. Schema::INTENTS already excludes the
  # non-candidate 'unknown' reason and includes 'unsupported', which is allowed here.
  ALLOWED_CAPABILITIES = Schema::INTENTS

  # Conservative bounds so a hostile/oversized config can never blow up the parse.
  MAX_CONFIG_BYTES = 8_000
  MAX_SCENARIOS = 200
  MAX_CAPABILITIES_PER_SCENARIO = Schema::INTENTS.length

  EMPTY = {}.freeze

  module_function

  # True ONLY for the exact safe true representation; every read failure folds to false.
  def enabled?
    read(ENABLED_KEY) == ENABLED_TRUE
  rescue StandardError
    false
  end

  # A frozen Hash { 'scenario_<id>' => [intent, ...] }, or the frozen EMPTY hash on ANY
  # anomaly. Never raises, never writes.
  def scenario_capabilities
    parse_capabilities(read(CAPABILITIES_KEY))
  rescue StandardError
    EMPTY
  end

  # Plain read of an InstallationConfig value as a String (nil -> ""). No write, no cache.
  def read(name)
    Marine::Llm::Config.installation_value(name)
  end

  # Parse and validate the whole config, failing the ENTIRE map closed to EMPTY on any
  # violation rather than partially trusting it. allow_duplicate_key: false rejects a
  # duplicate scenario key at parse time (a last-key-wins parse could otherwise hide one).
  def parse_capabilities(raw)
    return EMPTY unless parseable?(raw)

    parsed = JSON.parse(raw, allow_duplicate_key: false)
    return EMPTY unless valid_root?(parsed)

    build_map(parsed)
  rescue JSON::ParserError, EncodingError
    EMPTY
  end

  def parseable?(raw)
    !raw.nil? && !raw.strip.empty? && raw.bytesize <= MAX_CONFIG_BYTES
  end

  def valid_root?(parsed)
    parsed.is_a?(Hash) && parsed.size <= MAX_SCENARIOS
  end

  def build_map(parsed)
    result = {}
    parsed.each do |key, value|
      return EMPTY unless valid_key?(key)

      caps = normalize_capabilities(value)
      return EMPTY if caps.nil?

      result[key.dup] = caps
    end
    result.freeze
  end

  def valid_key?(key)
    key.is_a?(String) && key.match?(SCENARIO_KEY_PATTERN)
  end

  # An explicit, deduped, canonically-ordered subset of the allowed capabilities, or nil
  # (which fails the whole config closed) on a wrong type, an over-bound length, an unknown
  # intent, or a duplicate. An empty array is a valid "declares no capability" entry.
  def normalize_capabilities(value)
    return nil unless value.is_a?(Array)
    return nil if value.length > MAX_CAPABILITIES_PER_SCENARIO
    return nil unless value.all? { |code| allowed_capability?(code) }
    return nil if value.uniq.length != value.length

    ALLOWED_CAPABILITIES.select { |intent| value.include?(intent) }.freeze
  end

  def allowed_capability?(code)
    code.is_a?(String) && ALLOWED_CAPABILITIES.include?(code)
  end
end
