require 'json'

# Fase 3A-2 — DEFAULT-OFF, strictly READ-ONLY configuration for the battery-local Marine
# PRODUCT AUTHORITY shadow. This is an INDEPENDENT control surface: it shares NO key, flag,
# allowlist, or semantic with the scenario-level Marine::Decision shadow/cutover
# (MARINE_DECISION_*). Product authority controls are product-authority specific and are never
# derived from, nor able to reinterpret, MARINE_DECISION_CUTOVER_*.
#
# It reads ONLY four InstallationConfig keys and NEVER writes, memoizes, raises, logs, or touches
# Redis/DB/a provider beyond a plain read:
#
#   MARINE_PRODUCT_AUTHORITY_SHADOW_ENABLED      — the explicit shadow switch. Off unless the
#                                                  EXACT value is 'true'; anything else
#                                                  (blank, 'false', '1', 'TRUE', text) is OFF.
#   MARINE_PRODUCT_AUTHORITY_SHADOW_ASSISTANT_IDS — a bounded JSON array of unique POSITIVE
#                                                  INTEGER assistant ids the product shadow is
#                                                  opt-in for (max 50). Fails the WHOLE list
#                                                  closed to [] on ANY anomaly (blank, malformed/
#                                                  oversize JSON, a non-array root, an out-of-
#                                                  bounds size, a non-integer / float / string /
#                                                  bool / zero / negative / oversize value, or a
#                                                  duplicate) and never partially trusts a list.
#   MARINE_PRODUCT_AUTHORITY_CANDIDATE_MODE      — the FUTURE product-candidate control. A closed
#                                                  enum; defaults to 'off' (legacy) on missing/
#                                                  blank/unknown/wrong-type/read error. This phase
#                                                  NEVER wires any mode into execution — the value
#                                                  is surfaced for a future controlled cutover and
#                                                  the CandidateGate remains closed regardless.
#   MARINE_PRODUCT_AUTHORITY_ROLLBACK            — the operator kill switch. When the EXACT
#                                                  value is 'true' it has the HIGHEST precedence and
#                                                  forces BOTH the shadow and any future candidate
#                                                  authority CLOSED for every assistant, so the very
#                                                  next turn/job reverts to legacy.
#
# `shadow_enabled_for?(assistant_id)` gates the LIVE product shadow per assistant: rollback NOT
# engaged AND the explicit flag exactly on AND the id present in the valid, non-empty allowlist.
# Every read is fresh — there is NO cached open state a rollback could lag behind (revalidated
# every turn/job). It performs no write, enqueues nothing, reads no metrics/provider, and is not
# consulted by any UI/controller/settings-write path.
module Marine::ProductAuthority::ShadowConfig
  SHADOW_ENABLED_KEY = 'MARINE_PRODUCT_AUTHORITY_SHADOW_ENABLED'.freeze
  ASSISTANT_IDS_KEY = 'MARINE_PRODUCT_AUTHORITY_SHADOW_ASSISTANT_IDS'.freeze
  CANDIDATE_MODE_KEY = 'MARINE_PRODUCT_AUTHORITY_CANDIDATE_MODE'.freeze
  ROLLBACK_KEY = 'MARINE_PRODUCT_AUTHORITY_ROLLBACK'.freeze

  # The ONLY stored value that turns a boolean flag on: the EXACT 'true'.
  TRUE_VALUE = 'true'.freeze

  # Closed candidate-mode vocabulary. 'off' is the safe legacy default; 'shadow' marks an
  # assistant an operator has staged for a FUTURE controlled candidate rollout. No value here
  # ever opens live authority in this phase (see CandidateGate).
  CANDIDATE_MODE_OFF = 'off'.freeze
  CANDIDATE_MODES = %w[off shadow].freeze

  # Conservative bounds so a hostile/oversized config can never blow up the parse. The product
  # allowlist is intentionally small — the product shadow is a deliberate, per-assistant opt-in.
  MAX_CONFIG_BYTES = 8_000
  MAX_ASSISTANT_IDS = 50
  MAX_ASSISTANT_ID = 9_223_372_036_854_775_807

  EMPTY_IDS = [].freeze

  module_function

  # True ONLY for the exact true representation; every read failure folds to false.
  def shadow_enabled?
    true_flag?(SHADOW_ENABLED_KEY)
  rescue StandardError
    false
  end

  # True ONLY when the operator kill switch is the exact 'true'. A read failure folds to
  # true (fail-closed = rollback engaged = revert to legacy), the safest state.
  def rollback?
    true_flag?(ROLLBACK_KEY)
  rescue StandardError
    true
  end

  # True ONLY when: a positive Integer id, rollback NOT engaged, the explicit shadow flag exactly
  # on, AND the id present in the valid non-empty allowlist. Rollback / a closed flag short-circuit
  # BEFORE the allowlist parse, so the kill switch reverts to legacy with no further work. Any
  # read/parse/type error folds to false. Never raises, never writes. Revalidated every call.
  def shadow_enabled_for?(assistant_id)
    return false unless assistant_id.is_a?(Integer) && assistant_id.positive?
    return false if rollback?
    return false unless shadow_enabled?

    assistant_allowlist.include?(assistant_id)
  rescue StandardError
    false
  end

  # The FUTURE candidate mode for an assistant. Always 'off' when rollback is engaged, when the
  # shadow is not enabled for the assistant, or on any anomaly — so a candidate mode can never be
  # read as staged while the shadow foundation is closed. Returns a closed-enum String.
  def candidate_mode_for(assistant_id)
    return CANDIDATE_MODE_OFF unless shadow_enabled_for?(assistant_id)

    mode = read(CANDIDATE_MODE_KEY).to_s.strip
    CANDIDATE_MODES.include?(mode) ? mode : CANDIDATE_MODE_OFF
  rescue StandardError
    CANDIDATE_MODE_OFF
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

  # True ONLY for the exact stored 'true' (no trimming): a padded/near-true value fails closed.
  def true_flag?(name)
    read(name).to_s == TRUE_VALUE
  end

  # Parse and validate the whole allowlist, failing the ENTIRE list closed to EMPTY_IDS on any
  # violation rather than partially trusting it. Strict WHOLE-VALUE parsing: only genuine positive
  # Integer members within bounds survive; a float, string, boolean, zero, negative, oversize
  # value, or a duplicate fails closed.
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
