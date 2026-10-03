require 'json'

# Fase 3A-2 — Battery-local, PRIVACY-SAFE Redis metrics store for the product-authority shadow
# (aggregate counters only). It records ONE validated Marine::ProductAuthority::ShadowObservation as
# pure INTEGER COUNTERS in a UTC daily hash, versioned and scoped ONLY by account + assistant + date:
#
#   marine:product_authority:shadow:metrics:v1:<account_id>:<assistant_id>:YYYYMMDD
#
# It stores NO per-message row/id, raw value, prompt, name, text, exception, or finer-than-daily
# timestamp. The ONLY fields are bounded counters whose every dynamic component is contract-validated
# against the closed vocabulary BEFORE it becomes a Redis field:
#
#   total, comparable,
#   exact_agreement, intent_agreement, slot_agreement, status_agreement,
#   quantity_inquiry.legacy|candidate,
#   legacy_status.<status>, candidate_status.<status>,
#   legacy_intent.<intent>, candidate_intent.<intent>,
#   legacy_slot.<slot>, candidate_slot.<slot>,
#   matrix.<legacyStatus>.<candidateStatus>   (comparable samples only)
#
# #record increments the bounded counter set and (re)sets a bounded 14-day TTL in ONE Redis MULTI —
# no SCAN/KEYS/broad delete. Any Redis failure returns false and never raises into the ShadowJob /
# primary flow. #snapshot reads ONLY the explicit <=14 daily keys (never a scan), merges the integer
# counters fail-closed, and returns a deep-frozen aggregate snapshot. It deliberately carries NO
# self-declared mutation field: a counter store could never truthfully MEASURE reply/state mutation,
# so it must not claim it — mutation-cleanliness is proven separately by the Evaluator-produced
# `mutation_proof` artifact that ShadowAcceptance requires. An invalid id / days / time / field /
# value / cardinality and any read error return a safe empty/error snapshot with NO raw details.
# There is deliberately NO reset/destructive method.
# rubocop:disable Metrics/ClassLength -- one cohesive privacy boundary: the closed counter
# vocabulary, its contract validation, the atomic write, and the bounded no-scan read all belong to
# the same fail-closed seam and split poorly.
class Marine::ProductAuthority::ShadowMetricsStore
  Outcome = Marine::ProductAuthority::ProductOutcome

  # Schema/version code baked into the key AND the snapshot so a future field change is a new
  # namespace, never an in-place reinterpretation of old counters.
  SCHEMA_VERSION = 'marine_product_authority_shadow_metrics_v1'.freeze
  KEY_PREFIX = 'marine:product_authority:shadow:metrics:v1'.freeze

  TTL_SECONDS = 14 * 24 * 60 * 60
  MAX_DAYS = 14
  # Defensive cardinality ceiling on the distinct fields a merge may carry. A larger set signals a
  # corrupted/hostile hash and fails the snapshot closed.
  MAX_FIELDS = 1024

  # Static, fully-enumerated counter fields.
  STATIC_FIELDS = %w[
    total comparable
    exact_agreement intent_agreement slot_agreement status_agreement
    quantity_inquiry.legacy quantity_inquiry.candidate
  ].freeze

  def self.record(observation)
    new.record(observation)
  end

  def self.snapshot(account_id:, assistant_id:, days: MAX_DAYS, now: Time.current)
    new.snapshot(account_id: account_id, assistant_id: assistant_id, days: days, now: now)
  end

  # Increment the bounded counters for one observation in a single MULTI and refresh the TTL.
  # Returns true on a genuine write, false on any invalid observation / field or Redis failure.
  def record(observation, now: Time.current)
    fields = counter_fields(observation)
    return false if fields.empty?

    write(daily_key(observation.account_id, observation.assistant_id, now), fields)
    true
  rescue StandardError
    false
  end

  # A deep-frozen aggregate snapshot over the explicit last `days` (<=14) daily keys. Reads only
  # those keys (no scan), merges non-negative integer counters, and fails closed to an error snapshot
  # on an invalid input, an unknown field, a non-integer value, or an over-cardinality hash.
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
  # arbitrary model/customer text can reach a Redis field; an out-of-contract component raises and
  # fails the whole record closed.
  def counter_fields(observation)
    fields = ['total']
    fields << status_field('legacy_status', observation.legacy_status)
    fields << status_field('candidate_status', observation.candidate_status)
    fields.concat(intent_fields('legacy_intent', observation.legacy_intents))
    fields.concat(intent_fields('candidate_intent', observation.candidate_intents))
    fields.concat(slot_fields('legacy_slot', observation.legacy_slot_ops))
    fields.concat(slot_fields('candidate_slot', observation.candidate_slot_ops))
    fields.concat(quantity_fields(observation))
    fields.concat(comparison_fields(observation))
    validate_fields!(fields)
    fields
  end

  def status_field(prefix, status)
    raise ArgumentError unless Outcome::STATUSES.include?(status)

    "#{prefix}.#{status}"
  end

  def intent_fields(prefix, intents)
    intents.map do |code|
      raise ArgumentError unless Outcome::INTENTS.include?(code)

      "#{prefix}.#{code}"
    end
  end

  def slot_fields(prefix, slot_ops)
    slot_ops.map do |code|
      raise ArgumentError unless Outcome::SLOT_OPS.include?(code)

      "#{prefix}.#{code}"
    end
  end

  def quantity_fields(observation)
    fields = []
    fields << 'quantity_inquiry.legacy' if observation.legacy_quantity_inquiry?
    fields << 'quantity_inquiry.candidate' if observation.candidate_quantity_inquiry?
    fields
  end

  # Comparable samples additionally record the agreement counters and the confusion-matrix cell. A
  # non-comparable (fallback) decision contributes only the counters above.
  def comparison_fields(observation)
    return [] unless observation.comparable?

    fields = ['comparable', matrix_field(observation.legacy_status, observation.candidate_status)]
    fields << 'exact_agreement' if observation.exact_match?
    fields << 'intent_agreement' if observation.intents_match?
    fields << 'slot_agreement' if observation.slots_match?
    fields << 'status_agreement' if observation.status_match?
    fields
  end

  def matrix_field(legacy_status, candidate_status)
    "matrix.#{status_token(legacy_status)}.#{status_token(candidate_status)}"
  end

  def status_token(status)
    raise ArgumentError unless Outcome::STATUSES.include?(status)

    status
  end

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

  def read_hashes(keys)
    Redis::Alfred.with do |conn|
      conn.pipelined do |pipeline|
        keys.each { |key| pipeline.hgetall(key) }
      end
    end
  end

  # Merge the daily hashes into one { field => integer } map, or nil when any field is unknown, any
  # value is not a non-negative integer, or the distinct-field cardinality is exceeded.
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

  def integer_value(value)
    return value if value.is_a?(Integer) && !value.negative?
    return nil unless value.is_a?(String) && value.match?(/\A\d+\z/)

    Integer(value, 10)
  end

  # A field is valid when it is a known static field or matches one dynamic pattern whose components
  # are ALL allowlisted. Anything else fails the snapshot closed.
  def valid_field?(field)
    return false unless field.is_a?(String)
    return true if STATIC_FIELDS.include?(field)

    prefix, rest = field.split('.', 2)
    return false if rest.nil?

    dynamic_field?(prefix, rest)
  end

  def dynamic_field?(prefix, rest)
    case prefix
    when 'legacy_status', 'candidate_status' then Outcome::STATUSES.include?(rest)
    when 'legacy_intent', 'candidate_intent' then Outcome::INTENTS.include?(rest)
    when 'legacy_slot', 'candidate_slot' then Outcome::SLOT_OPS.include?(rest)
    when 'matrix' then valid_matrix_rest?(rest)
    else false
    end
  end

  def valid_matrix_rest?(rest)
    legacy, candidate = rest.split('.', 2)
    Outcome::STATUSES.include?(legacy) && Outcome::STATUSES.include?(candidate.to_s)
  end

  # --- keys / snapshots -----------------------------------------------------------------

  def daily_key(account_id, assistant_id, now)
    "#{KEY_PREFIX}:#{account_id}:#{assistant_id}:#{day_stamp(now)}"
  end

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

  # The snapshot carries ONLY aggregate counters. It makes NO self-declared mutation claim: the store
  # records only counters and mutates NO reply/routing/action/state/handoff/delivery/persistence, but
  # that safety is proven by the Evaluator's measured `mutation_proof`, never asserted here.
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
