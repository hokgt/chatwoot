# PURE, ADVISORY acceptance gate for the Marine Decision shadow (Phase 2 / Stage 5 —
# observation/advisory only). It consumes ONLY a validated Marine::Decision::ShadowMetricsStore
# snapshot and returns a deep-frozen report of bounded counts/rates against fixed, conservative
# production thresholds. It is NOT authority: it NEVER mutates config, enables a switch, calls
# the Runner/provider, reads Redis/DB, or implies automatic cutover.
#
# Fixed thresholds:
#   * at least MIN_TOTAL total samples and MIN_COMPARABLE comparable samples,
#   * at most MAX_ERROR_BPS non-normalized (fallback) rate,
#   * at most MAX_DECISION_SCENARIO_NONE_BPS decision-scenario-none rate,
#   * at least MIN_AGREEMENT_BPS exact legacy-vs-decision agreement among comparable samples.
#
# Every rate is computed in deterministic INTEGER BASIS POINTS (out of 10_000) with an explicit
# denominator, and every threshold comparison cross-multiplies to stay exact (no float, no
# divide-by-zero). Status is EXACTLY one of insufficient_data / hold / eligible_for_review;
# `eligible_for_review` is advisory only — it is NOT a cutover and Stage 6 remains default-off.
#
# Before evaluating thresholds it binds the input to the EXACT genuine ShadowMetricsStore
# ok-snapshot contract (schema version, ok flag, positive integer ids, in-range days, exact
# top-level key set, counters Hash) and enforces every recorder conservation law — the mutually-
# exclusive reason/confidence/decision/legacy families each summing to total, comparable ==
# normalized == agreement+disagreement == matrix-sum, and the bounded intent/slot multiplicity.
# A forged/malformed snapshot fails closed to hold/invalid_snapshot; a well-formed but
# arithmetically impossible counter set fails closed to hold/inconsistent_counters.
# rubocop:disable Metrics/ClassLength -- one cohesive fail-closed gate: the exact snapshot
# contract, the full conservation-law suite, and the integer-basis-point threshold evaluation all
# belong to the same advisory boundary and split poorly across classes.
class Marine::Decision::ShadowAcceptance
  Schema = Marine::Decision::Schema
  Store = Marine::Decision::ShadowMetricsStore

  SCHEMA_VERSION = 'marine_decision_shadow_acceptance_v1'.freeze

  # Conservative production constants.
  MIN_TOTAL = 50
  MIN_COMPARABLE = 30
  BASIS = 10_000
  MAX_ERROR_BPS = 500                    # 5%
  MAX_DECISION_SCENARIO_NONE_BPS = 1_000 # 10%
  MIN_AGREEMENT_BPS = 8_000              # 80%

  # Closed status + reason vocabularies. `cutover` is DELIBERATELY absent.
  STATUS_INSUFFICIENT = 'insufficient_data'.freeze
  STATUS_HOLD = 'hold'.freeze
  STATUS_ELIGIBLE = 'eligible_for_review'.freeze

  # The EXACT top-level key set a genuine ShadowMetricsStore ok-snapshot carries. A forged
  # snapshot missing one of these, or carrying any extra key, is rejected (fails closed) so an
  # arbitrary shape can never be evaluated as if it were a real metrics snapshot.
  EXPECTED_SNAPSHOT_KEYS = %i[schema_version ok account_id assistant_id days counters].freeze

  def self.evaluate(snapshot)
    new.evaluate(snapshot)
  end

  # A deep-frozen advisory report for the given snapshot. Never raises.
  def evaluate(snapshot)
    counts = counts_from(snapshot)
    return report(STATUS_HOLD, 'invalid_snapshot', nil) if counts.nil?
    return report(STATUS_HOLD, 'inconsistent_counters', counts) unless consistent?(counts)
    return report(STATUS_INSUFFICIENT, insufficient_reason(counts), counts) if insufficient?(counts)

    hold = hold_reason(counts)
    return report(STATUS_HOLD, hold, counts) if hold

    report(STATUS_ELIGIBLE, 'thresholds_met', counts)
  rescue StandardError
    report(STATUS_HOLD, 'invalid_snapshot', nil)
  end

  private

  # Pull the bounded integer counts the gate needs from a GENUINE ShadowMetricsStore ok-snapshot;
  # nil for any non-ok / forged / malformed snapshot so the caller folds to hold/invalid_snapshot.
  # It binds to the store's exact snapshot contract (schema version, ok flag, positive integer
  # ids, in-range days, exact top-level key set, counters Hash) before reading a single counter,
  # then extracts every aggregate the conservation laws need. A non-integer/negative counter
  # value raises ArgumentError (caught upstream -> invalid_snapshot).
  def counts_from(snapshot)
    return nil unless genuine_snapshot?(snapshot)

    aggregate(snapshot[:counters])
  end

  # Extract every aggregate the conservation laws + thresholds need from a validated counters
  # Hash, built from small grouped partials. A non-integer/negative value raises upstream.
  def aggregate(counters)
    total = count(counters, 'total')
    base_counts(counters, total)
      .merge(family_counts(counters))
      .merge(comparable_counts(counters))
      .merge(multiplicity_counts(counters))
  end

  def base_counts(counters, total)
    normalized = count(counters, "reason.#{Schema::REASON_NORMALIZED}")
    {
      total: total,
      normalized: normalized,
      errors: total - normalized,
      comparable: count(counters, 'comparable')
    }
  end

  def family_counts(counters)
    {
      decision_none: count(counters, 'decision_scenario.none'),
      decision_present: count(counters, 'decision_scenario.present'),
      legacy_none: count(counters, 'legacy_scenario.none'),
      legacy_present: count(counters, 'legacy_scenario.present'),
      reason_sum: sum_fields(counters, reason_fields),
      confidence_sum: sum_fields(counters, confidence_fields)
    }
  end

  def comparable_counts(counters)
    {
      agreement: count(counters, 'agreement'),
      disagreement: count(counters, 'disagreement'),
      matrix_sum: prefix_values(counters, 'matrix.').sum
    }
  end

  def multiplicity_counts(counters)
    intents = prefix_values(counters, 'intent.')
    slots = prefix_values(counters, 'slot.')
    {
      intent_sum: intents.sum,
      intent_max: intents.max || 0,
      slot_sum: slots.sum,
      slot_max: slots.max || 0
    }
  end

  # The snapshot must be EXACTLY a genuine ShadowMetricsStore ok-snapshot: same schema version,
  # ok true, positive integer account/assistant ids, integer days within the store's retention
  # window, the exact top-level key set (no missing/extra keys), and a Hash of counters.
  def genuine_snapshot?(snapshot)
    snapshot.is_a?(Hash) &&
      snapshot[:ok] == true &&
      snapshot[:schema_version] == Store::SCHEMA_VERSION &&
      exact_keys?(snapshot) &&
      valid_scope?(snapshot) &&
      snapshot[:counters].is_a?(Hash)
  end

  def valid_scope?(snapshot)
    positive_int?(snapshot[:account_id]) &&
      positive_int?(snapshot[:assistant_id]) &&
      valid_days?(snapshot[:days])
  end

  def exact_keys?(snapshot)
    keys = snapshot.keys
    keys.length == EXPECTED_SNAPSHOT_KEYS.length && EXPECTED_SNAPSHOT_KEYS.all? { |key| keys.include?(key) }
  end

  def positive_int?(value)
    value.is_a?(Integer) && value.positive?
  end

  def valid_days?(value)
    value.is_a?(Integer) && value.between?(1, Store::MAX_DAYS)
  end

  def count(counters, field)
    value = counters.fetch(field, 0)
    raise ArgumentError unless value.is_a?(Integer) && !value.negative?

    value
  end

  # The non-negative integer values of every counter whose field starts with the given dynamic
  # prefix (intent./slot./matrix.). A non-integer/negative value raises -> invalid_snapshot.
  def prefix_values(counters, prefix)
    counters.keys.select { |field| field.is_a?(String) && field.start_with?(prefix) }
            .map { |field| count(counters, field) }
  end

  def sum_fields(counters, fields)
    fields.sum { |field| count(counters, field) }
  end

  def reason_fields
    Schema::REASONS.map { |reason| "reason.#{reason}" }
  end

  def confidence_fields
    Schema::CONFIDENCE_LEVELS.map { |level| "confidence.#{level}" }
  end

  # Every recorder conservation law that a genuine ShadowMetricsStore snapshot must satisfy,
  # enforced BEFORE any threshold evaluation. A single violation fails the snapshot closed to
  # hold/inconsistent_counters. The laws mirror exactly how ShadowObservation/ShadowMetricsStore
  # increment counters for one observation.
  def consistent?(counts)
    subsets_ok?(counts) && sums_ok?(counts) && comparable_ok?(counts) && cardinality_ok?(counts)
  end

  # Every subset counter is bounded by its denominator (and, since each is non-negative, the
  # derived error count is non-negative too).
  def subsets_ok?(counts)
    totals_bounded?(counts) && comparable_bounded?(counts)
  end

  def totals_bounded?(counts)
    counts[:normalized] <= counts[:total] &&
      counts[:comparable] <= counts[:total] &&
      counts[:decision_none] <= counts[:total] &&
      counts[:decision_present] <= counts[:total] &&
      counts[:legacy_none] <= counts[:total] &&
      counts[:legacy_present] <= counts[:total]
  end

  def comparable_bounded?(counts)
    counts[:agreement] <= counts[:comparable] &&
      counts[:disagreement] <= counts[:comparable]
  end

  # Each mutually-exclusive family sums to exactly the total: every observation records exactly
  # one reason, one confidence, one decision-scenario presence, and one legacy-scenario presence.
  def sums_ok?(counts)
    counts[:reason_sum] == counts[:total] &&
      counts[:confidence_sum] == counts[:total] &&
      (counts[:decision_none] + counts[:decision_present]) == counts[:total] &&
      (counts[:legacy_none] + counts[:legacy_present]) == counts[:total]
  end

  # The comparable family is internally consistent: a comparable sample is exactly a normalized
  # one, and every comparable sample contributes exactly one agreement/disagreement outcome and
  # one confusion-matrix cell.
  def comparable_ok?(counts)
    counts[:comparable] == counts[:normalized] &&
      counts[:comparable] == (counts[:agreement] + counts[:disagreement]) &&
      counts[:comparable] == counts[:matrix_sum]
  end

  # Intent/slot increments stay within their per-observation multiplicity: each single counter is
  # bounded by total, and the total increments cannot exceed total * the per-observation cap.
  def cardinality_ok?(counts)
    counts[:intent_max] <= counts[:total] &&
      counts[:intent_sum] <= counts[:total] * Schema::MAX_INTENTS &&
      counts[:slot_max] <= counts[:total] &&
      counts[:slot_sum] <= counts[:total] * Schema::SLOTS.length
  end

  def insufficient?(counts)
    counts[:total] < MIN_TOTAL || counts[:comparable] < MIN_COMPARABLE
  end

  def insufficient_reason(counts)
    counts[:total] < MIN_TOTAL ? 'insufficient_total' : 'insufficient_comparable'
  end

  # The first failing quality gate, or nil when all pass. Denominators are explicit and every
  # comparison cross-multiplies so a zero denominator can never divide.
  def hold_reason(counts)
    return 'error_rate_exceeded' if counts[:errors] * BASIS > MAX_ERROR_BPS * counts[:total]
    return 'decision_none_rate_exceeded' if counts[:decision_none] * BASIS > MAX_DECISION_SCENARIO_NONE_BPS * counts[:total]
    return 'agreement_below_threshold' if counts[:agreement] * BASIS < MIN_AGREEMENT_BPS * counts[:comparable]

    nil
  end

  # Integer basis-point rate with an explicit denominator; a zero denominator yields 0 rather
  # than dividing.
  def rate_bps(numerator, denominator)
    return 0 if denominator.zero?

    (numerator * BASIS) / denominator
  end

  def report(status, reason, counts)
    deep_freeze(
      schema_version: SCHEMA_VERSION,
      status: status,
      reason: reason,
      samples: samples(counts),
      rates_bps: rates(counts),
      thresholds: thresholds
    )
  end

  def samples(counts)
    return {} if counts.nil?

    {
      total: counts[:total],
      comparable: counts[:comparable],
      errors: counts[:errors],
      decision_scenario_none: counts[:decision_none],
      agreement: counts[:agreement]
    }
  end

  def rates(counts)
    return {} if counts.nil?

    {
      error: rate_bps(counts[:errors], counts[:total]),
      decision_scenario_none: rate_bps(counts[:decision_none], counts[:total]),
      agreement: rate_bps(counts[:agreement], counts[:comparable])
    }
  end

  def thresholds
    {
      min_total: MIN_TOTAL,
      min_comparable: MIN_COMPARABLE,
      max_error_bps: MAX_ERROR_BPS,
      max_decision_scenario_none_bps: MAX_DECISION_SCENARIO_NONE_BPS,
      min_agreement_bps: MIN_AGREEMENT_BPS
    }
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
