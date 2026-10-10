require 'json'

# STRICT, fail-closed cutover configuration for the battery-local Marine Decision Maker
# scenario-selection cutover (Phase 2 / Stage 6 — controlled authority). It reads ONLY three
# InstallationConfig keys and NEVER writes, memoizes, raises, logs, or touches Redis/DB/a
# provider beyond a plain read:
#
#   MARINE_DECISION_CUTOVER_ENABLED    — off unless the EXACT trimmed value is 'true'; any
#                                        other value (blank, 'false', '1', 'TRUE', text) is OFF.
#   MARINE_DECISION_CUTOVER_ASSISTANT_IDS — a bounded JSON array of unique POSITIVE INTEGER
#                                        assistant ids the cutover is opt-in for (max 50). It
#                                        fails the WHOLE list closed to [] on ANY anomaly
#                                        (blank, malformed/oversize JSON, a non-array root, an
#                                        out-of-bounds size, a non-integer / float / string /
#                                        bool / zero / negative / oversize value, or a
#                                        duplicate) and never partially trusts a suspect list.
#   MARINE_DECISION_CUTOVER_ROLLBACK   — the operator kill switch. When the EXACT trimmed value
#                                        is 'true' it has the HIGHEST precedence and forces the
#                                        cutover CLOSED for every assistant, ignoring enable +
#                                        allowlists, so the very next selection reverts to legacy.
#
# `enabled_for?(assistant_id)` opens the cutover per assistant ONLY when: the id is a positive
# Integer, rollback is NOT engaged, the global flag is exactly on, the id is in the valid
# non-empty cutover allowlist, AND the existing Marine::Decision::ShadowConfig.enabled_for? is
# still true for that id — so a cut-over assistant always remains under the live shadow +
# allowlist and ongoing observation never stops. Rollback / a closed config short-circuit BEFORE
# any allowlist parse, so the kill switch (and any read error) reverts to legacy with no further
# work. It performs NO write, enqueues nothing, reads no metrics/provider, and is not consulted
# by any UI/controller/settings-write path. Every read is fresh — there is NO memoized switch a
# rollback could lag behind.
module Marine::Decision::CutoverConfig
  ShadowConfig = Marine::Decision::ShadowConfig

  ENABLED_KEY = 'MARINE_DECISION_CUTOVER_ENABLED'.freeze
  ASSISTANT_IDS_KEY = 'MARINE_DECISION_CUTOVER_ASSISTANT_IDS'.freeze
  ROLLBACK_KEY = 'MARINE_DECISION_CUTOVER_ROLLBACK'.freeze

  # The ONLY stored value that turns a flag on: the EXACT trimmed 'true'.
  TRUE_VALUE = 'true'.freeze

  # Conservative bounds so a hostile/oversized config can never blow up the parse. The cutover
  # allowlist is intentionally SMALLER than the shadow allowlist: cutover is a deliberate,
  # per-assistant rollout, not a broad opt-in.
  MAX_CONFIG_BYTES = 8_000
  MAX_ASSISTANT_IDS = 50
  MAX_ASSISTANT_ID = 9_223_372_036_854_775_807

  EMPTY_IDS = [].freeze

  module_function

  # True ONLY for the exact trimmed true representation; any read failure folds to false.
  def enabled?
    true_flag?(ENABLED_KEY)
  rescue StandardError
    false
  end

  # True ONLY when the operator kill switch is the exact trimmed 'true'. A read failure folds
  # to true (fail-closed = rollback engaged = revert to legacy), the safest state.
  def rollback?
    true_flag?(ROLLBACK_KEY)
  rescue StandardError
    true
  end

  # True ONLY when: a positive Integer id, rollback NOT engaged, the global flag exactly on, the
  # id present in the valid non-empty cutover allowlist, AND the shadow is still enabled for that
  # id (so shadow + allowlist keep running under cutover). Rollback / a closed config are checked
  # BEFORE the allowlist parse and BEFORE ShadowConfig, so the kill switch reverts to legacy with
  # no further work. Any read/parse/type error folds to false. Never raises, never writes.
  def enabled_for?(assistant_id)
    return false unless assistant_id.is_a?(Integer) && assistant_id.positive?
    return false if rollback?
    return false unless enabled?
    return false unless assistant_allowlist.include?(assistant_id)

    ShadowConfig.enabled_for?(assistant_id)
  rescue StandardError
    false
  end

  # A frozen Array of unique positive Integer assistant ids, or the frozen EMPTY_IDS array on ANY
  # anomaly. Never raises, never writes.
  def assistant_allowlist
    parse_assistant_ids(read(ASSISTANT_IDS_KEY))
  rescue StandardError
    EMPTY_IDS
  end

  # Plain read of an InstallationConfig value as a String (nil -> ""). No write, no cache.
  def read(name)
    Marine::Llm::Config.installation_value(name)
  end

  # True ONLY for the exact trimmed 'true'; every other value is off.
  def true_flag?(name)
    read(name).to_s.strip == TRUE_VALUE
  end

  # Parse and validate the whole allowlist, failing the ENTIRE list closed to EMPTY_IDS on any
  # violation rather than partially trusting it. Strict WHOLE-VALUE parsing: only genuine
  # positive Integer members within bounds survive; a float, string, boolean, zero, negative,
  # oversize value, or a duplicate fails closed.
  def parse_assistant_ids(raw)
    return EMPTY_IDS unless parseable?(raw)

    parsed = JSON.parse(raw)
    return EMPTY_IDS unless valid_id_root?(parsed)

    build_ids(parsed)
  rescue JSON::ParserError, EncodingError
    EMPTY_IDS
  end

  def parseable?(raw)
    !raw.nil? && !raw.strip.empty? && raw.bytesize <= MAX_CONFIG_BYTES
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
