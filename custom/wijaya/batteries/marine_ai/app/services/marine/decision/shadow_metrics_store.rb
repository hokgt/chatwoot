require 'json'

# Battery-local, PRIVACY-SAFE Redis metrics store for the Marine Decision shadow (Phase 2 /
# Stage 5 — aggregate metrics only). It records ONE validated Marine::Decision::ShadowObservation
# as pure INTEGER COUNTERS in a UTC daily hash, versioned and scoped ONLY by account + assistant
# + date:
#
#   marine:decision:shadow:metrics:v1:<account_id>:<assistant_id>:YYYYMMDD
#
# It stores NO per-message row/id, raw value, prompt, name, text, exception, or finer-than-daily
# timestamp. The ONLY fields are bounded counters whose every dynamic component is
# contract-validated against the closed vocabulary BEFORE it becomes a Redis field:
#
#   total, comparable, agreement, disagreement,
#   reason.<allowlisted>, confidence.<allowlisted>,
#   decision_scenario.none|present, legacy_scenario.none|present,
#   intent.<allowlisted>, slot.<operation>.<slot>,
#   matrix.<legacyKeyOrNone>.<decisionKeyOrNone>   (stable `scenario_<id>` keys or none)
#
# #record increments the bounded counter set and (re)sets a bounded 14-day TTL in ONE Redis
# MULTI through Redis::Alfred.with — no SCAN/KEYS/broad delete. Any Redis failure returns false
# and never raises into the ShadowJob / primary flow.
#
# #snapshot reads ONLY the explicit <=14 daily keys (never a scan), merges the integer counters
# fail-closed, and returns a deep-frozen aggregate snapshot. It rejects an invalid id / days /
# time / field / value / cardinality and a read error returns a safe empty/error snapshot with
# NO raw details. There is deliberately NO reset/destructive method.
# rubocop:disable Metrics/ClassLength -- one cohesive privacy boundary: the closed counter
# vocabulary, its contract validation, the atomic write, and the bounded no-scan read all belong
# to the same fail-closed seam and split poorly.
class Marine::Decision::ShadowMetricsStore
  Schema = Marine::Decision::Schema
  Config = Marine::Decision::ShadowConfig

  # Schema/version code baked into the key AND the snapshot so a future field change is a new
  # namespace, never an in-place reinterpretation of old counters.
  SCHEMA_VERSION = 'marine_decision_shadow_metrics_v1'.freeze
  KEY_PREFIX = 'marine:decision:shadow:metrics:v1'.freeze

  # 14-day bounded lifetime for every daily bucket.
  TTL_SECONDS = 14 * 24 * 60 * 60
  # The snapshot window can never read more than the retention window of daily keys.
  MAX_DAYS = 14
  # Defensive cardinality ceiling on the distinct fields a merge may carry (statics + reasons +
  # confidences + intents + slots + the bounded scenario confusion matrix). A larger set signals
  # a corrupted/hostile hash and fails the snapshot closed.
  MAX_FIELDS = 1024

  # The `none` token stands in for a nil scenario key in a field component.
  NONE = 'none'.freeze

  # Static, fully-enumerated counter fields.
  STATIC_FIELDS = %w[
    total comparable agreement disagreement
    decision_scenario.none decision_scenario.present
    legacy_scenario.none legacy_scenario.present
  ].freeze

  def self.record(observation)
    new.record(observation)
  end

  def self.snapshot(account_id:, assistant_id:, days: MAX_DAYS, now: Time.current)
    new.snapshot(account_id: account_id, assistant_id: assistant_id, days: days, now: now)
  end

  # Increment the bounded counters for one observation in a single MULTI and refresh the TTL.
  # Returns true on a genuine write, false on any invalid observation / field or Redis failure.
  # Never raises.
  def record(observation, now: Time.current)
    fields = counter_fields(observation)
    return false if fields.empty?

    key = daily_key(observation.account_id, observation.assistant_id, now)
    write(key, fields)
    true
  rescue StandardError
    false
  end

  # A deep-frozen aggregate snapshot over the explicit last `days` (<=14) daily keys. Reads only
  # those keys (no scan), merges non-negative integer counters, and fails closed to an error
  # snapshot on an invalid input, an unknown field, a non-integer value, or an over-cardinality
  # hash. A read error returns a safe error snapshot with no raw detail.
  def snapshot(account_id:, assistant_id:, days: MAX_DAYS, now: Time.current)
    return error_snapshot('invalid_input') unless valid_snapshot_input?(account_id, assistant_id, days, now)

    keys = daily_keys(account_id, assistant_id, days, now)
    merged = merge_counters(read_hashes(keys))
    return error_snapshot('invalid_counters') if merged.nil?

    ok_snapshot(account_id, assistant_id, days, merged)
  rescue StandardError
    error_snapshot('read_error')
  end

  private

  # --- write path -----------------------------------------------------------------------

  # The bounded, contract-validated field list for one observation. Every dynamic component is
  # re-checked against the closed vocabulary here (defense in depth over the observation) so no
  # arbitrary model/customer text can reach a Redis field; an out-of-contract component raises
  # and fails the whole record closed.
  def counter_fields(observation)
    fields = ['total']
    fields << reason_field(observation.reason)
    fields << confidence_field(observation.confidence)
    fields << presence_field('decision_scenario', observation.decision_present?)
    fields << presence_field('legacy_scenario', observation.legacy_present?)
    fields.concat(intent_fields(observation.intents))
    fields.concat(slot_fields(observation.slot_pairs))
    fields.concat(comparison_fields(observation))
    validate_fields!(fields)
    fields
  end

  def reason_field(reason)
    raise ArgumentError unless Schema::REASONS.include?(reason)

    "reason.#{reason}"
  end

  def confidence_field(confidence)
    raise ArgumentError unless Schema::CONFIDENCE_LEVELS.include?(confidence)

    "confidence.#{confidence}"
  end

  def presence_field(prefix, present)
    "#{prefix}.#{present ? 'present' : NONE}"
  end

  def intent_fields(intents)
    intents.map do |code|
      raise ArgumentError unless Schema::INTENTS.include?(code)

      "intent.#{code}"
    end
  end

  def slot_fields(slot_pairs)
    slot_pairs.map do |operation, slot|
      raise ArgumentError unless Schema::SLOT_OPERATIONS.include?(operation) && Schema::SLOTS.include?(slot)

      "slot.#{operation}.#{slot}"
    end
  end

  # Comparable samples additionally record agreement/disagreement and the confusion-matrix cell.
  # A non-comparable (fallback) decision has no meaningful scenario decision to compare, so it
  # contributes only the counters above.
  def comparison_fields(observation)
    return [] unless observation.comparable?

    ['comparable',
     observation.match? ? 'agreement' : 'disagreement',
     matrix_field(observation.legacy_key, observation.decision_key)]
  end

  def matrix_field(legacy_key, decision_key)
    "matrix.#{scenario_token(legacy_key)}.#{scenario_token(decision_key)}"
  end

  # nil -> none; a present key must be a canonical `scenario_<id>` stable key or the field is
  # rejected (fails the whole record closed).
  def scenario_token(key)
    return NONE if key.nil?
    raise ArgumentError unless key.is_a?(String) && key.match?(Config::SCENARIO_KEY_PATTERN)

    key
  end

  # Final gate: every field must be a recognized counter field and the whole set within the
  # cardinality ceiling.
  def validate_fields!(fields)
    raise ArgumentError if fields.length > MAX_FIELDS
    raise ArgumentError unless fields.all? { |field| valid_field?(field) }
  end

  def write(key, fields)
    Redis::Alfred.with do |conn|
      conn.multi do |transaction|
        fields.each { |field| transaction.hincrby(key, field, 1) }
        transaction.expire(key, TTL_SECONDS)
      end
    end
  end

  # --- read path ------------------------------------------------------------------------

  def valid_snapshot_input?(account_id, assistant_id, days, now)
    positive_int?(account_id) && positive_int?(assistant_id) &&
      days.is_a?(Integer) && days.between?(1, MAX_DAYS) &&
      now.respond_to?(:utc)
  end

  # Read each explicit daily key's hash in one pipeline (no scan). Returns an array of hashes.
  def read_hashes(keys)
    Redis::Alfred.with do |conn|
      conn.pipelined do |pipeline|
        keys.each { |key| pipeline.hgetall(key) }
      end
    end
  end

  # Merge the daily hashes into one { field => integer } map, or nil when any field is unknown,
  # any value is not a non-negative integer, or the distinct-field cardinality is exceeded.
  def merge_counters(hashes)
    merged = Hash.new(0)
    hashes.each do |hash|
      return nil unless hash.is_a?(Hash)

      hash.each do |field, value|
        return nil unless valid_field?(field)

        count = integer_value(value)
        return nil if count.nil?

        merged[field] += count
        return nil if merged.size > MAX_FIELDS
      end
    end
    merged
  end

  # A non-negative integer parsed from an exact decimal string (Redis hash values are strings).
  # Anything else (negative, float, non-numeric, blank) is rejected.
  def integer_value(value)
    return value if value.is_a?(Integer) && !value.negative?
    return nil unless value.is_a?(String) && value.match?(/\A\d+\z/)

    Integer(value, 10)
  end

  # A field is valid when it is a known static field or matches one dynamic pattern whose
  # components are ALL allowlisted. Anything else fails the snapshot closed.
  def valid_field?(field)
    return false unless field.is_a?(String)
    return true if STATIC_FIELDS.include?(field)

    prefix, rest = field.split('.', 2)
    return false if rest.nil?

    dynamic_field?(prefix, rest)
  end

  def dynamic_field?(prefix, rest)
    case prefix
    when 'reason' then Schema::REASONS.include?(rest)
    when 'confidence' then Schema::CONFIDENCE_LEVELS.include?(rest)
    when 'intent' then Schema::INTENTS.include?(rest)
    when 'slot' then valid_slot_rest?(rest)
    when 'matrix' then valid_matrix_rest?(rest)
    else false
    end
  end

  def valid_slot_rest?(rest)
    operation, slot = rest.split('.', 2)
    Schema::SLOT_OPERATIONS.include?(operation) && Schema::SLOTS.include?(slot.to_s)
  end

  def valid_matrix_rest?(rest)
    legacy, decision = rest.split('.', 2)
    scenario_token_valid?(legacy) && scenario_token_valid?(decision.to_s)
  end

  def scenario_token_valid?(token)
    token == NONE || token.match?(Config::SCENARIO_KEY_PATTERN)
  end

  # --- keys / snapshots -----------------------------------------------------------------

  def daily_key(account_id, assistant_id, now)
    "#{KEY_PREFIX}:#{account_id}:#{assistant_id}:#{day_stamp(now)}"
  end

  # The explicit set of daily keys for the window [today-(days-1) .. today], each stamped in
  # UTC. Bounded by `days` (<=14); no scan/pattern is ever used.
  def daily_keys(account_id, assistant_id, days, now)
    base = now.utc
    (0...days).map do |offset|
      stamp = (base - (offset * 86_400)).strftime('%Y%m%d')
      "#{KEY_PREFIX}:#{account_id}:#{assistant_id}:#{stamp}"
    end
  end

  def day_stamp(now)
    now.utc.strftime('%Y%m%d')
  end

  def ok_snapshot(account_id, assistant_id, days, counters)
    deep_freeze(
      schema_version: SCHEMA_VERSION,
      ok: true,
      account_id: account_id,
      assistant_id: assistant_id,
      days: days,
      counters: counters.to_h
    )
  end

  # A safe, deep-frozen error snapshot carrying only an allowlisted reason code and empty
  # counters — never a raw id, field, value, or exception detail.
  def error_snapshot(reason)
    deep_freeze(
      schema_version: SCHEMA_VERSION,
      ok: false,
      reason: reason,
      counters: {}
    )
  end

  def positive_int?(value)
    value.is_a?(Integer) && value.positive?
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end
end
# rubocop:enable Metrics/ClassLength
