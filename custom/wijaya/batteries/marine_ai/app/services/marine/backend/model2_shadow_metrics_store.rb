# Langkah 3 observability — Battery-local, PRIVACY-SAFE Redis metrics store for the Model 2 shadow
# (aggregate counters only). It records ONE validated Marine::Backend::Model2ShadowObservation as pure
# INTEGER COUNTERS in a UTC daily hash, versioned and scoped ONLY by date — NEVER by account,
# assistant, conversation, contact, message, or any other identifier:
#
#   marine:model2:shadow:metrics:v1:YYYYMMDD
#
# The ONLY fields are a fully-enumerated, fully-STATIC allowlist (there is no dynamic key component at
# all): `total` plus one `<status>.<reason>` counter for each exact pair the execution can emit. A
# field outside that fixed allowlist can never be written or read, so no customer/model text, price,
# code, id, prompt, or provider output can ever reach a Redis field.
#
# #record increments the bounded counter set and (re)sets a bounded 14-day TTL in ONE Redis MULTI — no
# SCAN/KEYS/broad delete. Any Redis failure returns false and never raises into the ShadowJob / primary
# flow. #snapshot reads ONLY the explicit <=14 daily keys (never a scan), merges non-negative integer
# counters fail-closed, and returns a deep-frozen aggregate snapshot; an invalid days/time, an unknown
# field, a non-integer value, or a read error returns a safe empty/error snapshot with NO raw detail.
# There is deliberately NO reset/destructive method.
class Marine::Backend::Model2ShadowMetricsStore
  Observation = Marine::Backend::Model2ShadowObservation

  # Schema/version code baked into the key AND the snapshot so a future field change is a new
  # namespace, never an in-place reinterpretation of old counters.
  SCHEMA_VERSION = 'marine_model2_shadow_metrics_v1'.freeze
  KEY_PREFIX = 'marine:model2:shadow:metrics:v1'.freeze

  # 14-day bounded lifetime for every daily bucket.
  TTL_SECONDS = 14 * 24 * 60 * 60
  # The snapshot window can never read more than the retention window of daily keys.
  MAX_DAYS = 14

  # The fully-enumerated `<status>.<reason>` counter fields, derived from the observation's closed
  # ALLOWED_PAIRS so the store can never drift from the projection's vocabulary.
  PAIR_FIELDS = Observation::ALLOWED_PAIRS.flat_map do |status, reasons|
    reasons.map { |reason| "#{status}.#{reason}" }
  end.freeze
  # The complete, static counter allowlist. There is NO dynamic key component — a field is valid iff
  # it is one of these exact strings.
  STATIC_FIELDS = (['total'] + PAIR_FIELDS).freeze

  def self.record(observation)
    new.record(observation)
  end

  def self.snapshot(days: MAX_DAYS, now: Time.current)
    new.snapshot(days: days, now: now)
  end

  # Increment `total` and the one `<status>.<reason>` counter for this observation in a single MULTI
  # and refresh the TTL. Returns true on a genuine write, false on any invalid observation / field or
  # Redis failure. Never raises.
  def record(observation, now: Time.current)
    fields = counter_fields(observation)
    return false if fields.empty?

    write(daily_key(now), fields)
    true
  rescue StandardError
    false
  end

  # A deep-frozen aggregate snapshot over the explicit last `days` (<=14) daily keys. Reads only those
  # keys (no scan), merges non-negative integer counters, and fails closed to an error snapshot on an
  # invalid input, an unknown field, or a non-integer value. A read error returns a safe error snapshot.
  def snapshot(days: MAX_DAYS, now: Time.current)
    return error_snapshot('invalid_input') unless valid_snapshot_input?(days, now)

    merged = merge_counters(read_hashes(daily_keys(days, now)))
    return error_snapshot('invalid_counters') if merged.nil?

    ok_snapshot(days, merged)
  rescue StandardError
    error_snapshot('read_error')
  end

  private

  # --- write path -----------------------------------------------------------------------

  # The bounded, contract-validated field list for one observation: always `total`, plus the single
  # pair counter. The pair is re-checked against the static allowlist here (defense in depth over the
  # observation) so an out-of-contract status/reason raises and fails the whole record closed.
  def counter_fields(observation)
    ['total', pair_field(observation)]
  end

  def pair_field(observation)
    field = "#{observation.status}.#{observation.reason}"
    raise ArgumentError unless PAIR_FIELDS.include?(field)

    field
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

  def valid_snapshot_input?(days, now)
    days.is_a?(Integer) && days.between?(1, MAX_DAYS) && now.respond_to?(:utc)
  end

  # Read each explicit daily key's hash in one pipeline (no scan). Returns an array of hashes.
  def read_hashes(keys)
    Redis::Alfred.with do |conn|
      conn.pipelined do |pipeline|
        keys.each { |key| pipeline.hgetall(key) }
      end
    end
  end

  # Merge the daily hashes into one { field => integer } map, or nil when any field is outside the
  # static allowlist or any value is not a non-negative integer.
  def merge_counters(hashes)
    merged = Hash.new(0)
    hashes.each do |hash|
      return nil unless hash.is_a?(Hash)

      hash.each do |field, value|
        return nil unless STATIC_FIELDS.include?(field)

        count = integer_value(value)
        return nil if count.nil?

        merged[field] += count
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

  # --- keys / snapshots -----------------------------------------------------------------

  def daily_key(now)
    "#{KEY_PREFIX}:#{day_stamp(now)}"
  end

  # The explicit set of daily keys for the window [today-(days-1) .. today], each stamped in UTC.
  # Bounded by `days` (<=14); no scan/pattern is ever used.
  def daily_keys(days, now)
    base = now.utc
    (0...days).map { |offset| "#{KEY_PREFIX}:#{(base - (offset * 86_400)).strftime('%Y%m%d')}" }
  end

  def day_stamp(now)
    now.utc.strftime('%Y%m%d')
  end

  def ok_snapshot(days, counters)
    deep_freeze(schema_version: SCHEMA_VERSION, ok: true, days: days, counters: counters.to_h)
  end

  # A safe, deep-frozen error snapshot carrying only an allowlisted reason code and empty counters —
  # never a raw field, value, or exception detail.
  def error_snapshot(reason)
    deep_freeze(schema_version: SCHEMA_VERSION, ok: false, reason: reason, counters: {})
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end
end
