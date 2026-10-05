require 'json'

# DEFAULT-OFF, strictly READ-ONLY shadow configuration for the battery-local Marine
# Decision Maker shadow execution (Phase 2 / Stage 4 shadow + Stage 5 aggregate metrics).
# It reads ONLY two InstallationConfig keys and NEVER writes, raises, logs, or touches
# Redis/DB beyond a plain read:
#
#   MARINE_DECISION_SHADOW_ENABLED       — off unless the stored value is the exact safe
#                                          true representation ('true'); anything else
#                                          (blank, 'false', '1', 'TRUE', arbitrary text)
#                                          is OFF.
#   MARINE_DECISION_SHADOW_ASSISTANT_IDS — a bounded JSON array of unique POSITIVE INTEGER
#                                          assistant ids the live shadow is opt-in for. It
#                                          fails CLOSED to NO assistants ([]) on ANY anomaly
#                                          (blank, malformed/oversize JSON, a non-array root,
#                                          an out-of-bounds size, a non-integer / float /
#                                          string / zero / negative / oversize value, or a
#                                          duplicate) and never partially trusts a suspect
#                                          list.
#
# Phase 1 (Opsi B): execution authorization and the Model 1 classification vocabulary are
# backend-policy-owned by the execution policy, so there is NO per-scenario capability
# registry here. MARINE_DECISION_SCENARIO_CAPABILITIES is simply no longer read (any stored value is
# an inert, unread orphan — never deleted or written).
#
# `enabled_for?(assistant_id)` gates the LIVE shadow per assistant: the exact global flag AND
# the assistant id being present in the valid, non-empty allowlist. A missing/invalid/empty
# allowlist keeps the shadow off for every assistant, so it is always opt-in and never touches
# Redis/a job/a provider/metrics for an unlisted assistant. It performs no write, enqueues
# nothing, and is not consulted by any UI/controller/settings-write path.
module Marine::Decision::ShadowConfig
  ENABLED_KEY = 'MARINE_DECISION_SHADOW_ENABLED'.freeze
  ASSISTANT_IDS_KEY = 'MARINE_DECISION_SHADOW_ASSISTANT_IDS'.freeze

  # The ONLY stored value that turns the shadow on. `InstallationConfig#value.to_s` renders
  # both a string "true" and a boolean true as "true", so this covers the safe true forms.
  ENABLED_TRUE = 'true'.freeze

  # Stable scenario-key format the ScenarioAdapter emits: `scenario_<database id>`. A bounded
  # digit run comfortably covers a bigint while keeping a hostile key small. Consumed by the
  # Stage-5 ShadowObservation to validate the stable comparison key (NOT a capability mechanism).
  SCENARIO_KEY_PATTERN = /\Ascenario_\d{1,19}\z/

  # Conservative bound so a hostile/oversized config can never blow up the parse.
  MAX_CONFIG_BYTES = 8_000

  # Bounds for the assistant allowlist: at most this many ids and no id above the PostgreSQL
  # bigint ceiling (a hostile oversized integer fails the WHOLE list closed).
  MAX_ASSISTANT_IDS = 200
  MAX_ASSISTANT_ID = 9_223_372_036_854_775_807

  EMPTY_IDS = [].freeze

  module_function

  # True ONLY for the exact safe true representation; every read failure folds to false.
  def enabled?
    read(ENABLED_KEY) == ENABLED_TRUE
  rescue StandardError
    false
  end

  # True ONLY when the exact global flag is on AND the given assistant id is present in the
  # valid, non-empty allowlist. A missing/invalid/empty allowlist, a non-positive-integer id,
  # or any read/parse/type error folds to false, so the live shadow is always opt-in and
  # assistant-scoped and never runs for an unlisted assistant. Never raises, never writes.
  def enabled_for?(assistant_id)
    return false unless enabled?
    return false unless assistant_id.is_a?(Integer) && assistant_id.positive?

    assistant_allowlist.include?(assistant_id)
  rescue StandardError
    false
  end

  # A frozen Array of unique positive Integer assistant ids, or the frozen EMPTY_IDS array on
  # ANY anomaly. Never raises, never writes.
  def assistant_allowlist
    parse_assistant_ids(read(ASSISTANT_IDS_KEY))
  rescue StandardError
    EMPTY_IDS
  end

  # Plain read of an InstallationConfig value as a String (nil -> ""). No write, no cache.
  def read(name)
    Marine::Llm::Config.installation_value(name)
  end

  def parseable?(raw)
    !raw.nil? && !raw.strip.empty? && raw.bytesize <= MAX_CONFIG_BYTES
  end

  # Parse and validate the whole allowlist, failing the ENTIRE list closed to EMPTY_IDS on any
  # violation rather than partially trusting it. Strict WHOLE-VALUE parsing: only genuine
  # positive Integer members survive; a float, string, boolean, zero, negative, oversize
  # value, or a duplicate fails closed.
  def parse_assistant_ids(raw)
    return EMPTY_IDS unless parseable?(raw)

    parsed = JSON.parse(raw)
    return EMPTY_IDS unless valid_id_root?(parsed)

    build_ids(parsed)
  rescue JSON::ParserError, EncodingError
    EMPTY_IDS
  end

  def valid_id_root?(parsed)
    parsed.is_a?(Array) && parsed.length <= MAX_ASSISTANT_IDS
  end

  # A frozen list of the unique positive Integer ids, or EMPTY_IDS when any member is not a
  # positive Integer within bounds or a duplicate is present.
  def build_ids(parsed)
    return EMPTY_IDS unless parsed.all? { |id| positive_id?(id) }
    return EMPTY_IDS if parsed.uniq.length != parsed.length

    parsed.dup.freeze
  end

  # Strictly a positive Integer within the bigint ceiling. Float (e.g. 5.0), String ("5"),
  # boolean, zero, and negative all fail closed.
  def positive_id?(id)
    id.is_a?(Integer) && id.positive? && id <= MAX_ASSISTANT_ID
  end
end
