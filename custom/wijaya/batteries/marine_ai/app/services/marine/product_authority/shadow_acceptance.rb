# Fase 3A-2 — PURE, ADVISORY acceptance gate over the LIVE product-authority shadow metrics. It
# consumes ONLY a validated Marine::ProductAuthority::ShadowMetricsStore snapshot and returns a
# deep-frozen report of bounded counts/rates against fixed, conservative thresholds. It is NOT
# authority: it NEVER mutates config, enables a switch, calls the Runner/provider/adapter, reads
# Redis/DB, or implies automatic cutover. It answers only "is the live shadow signal statistically
# ready for a human to REVIEW a future product-candidate rollout?" — never "cut over now".
#
# Fixed thresholds:
#   * at least MIN_TOTAL total samples and MIN_COMPARABLE comparable samples,
#   * at least MIN_EXACT_AGREEMENT_BPS exact legacy-vs-candidate agreement among comparable samples,
#   * at most MAX_CANDIDATE_BLOCKED_BPS candidate-blocked (adapter-failed) rate.
#
# Every rate is computed in deterministic INTEGER BASIS POINTS (out of 10_000) with an explicit
# denominator and cross-multiplied comparisons (no float, no divide-by-zero). Status is EXACTLY one of
# insufficient_data / hold / eligible_for_review; `eligible_for_review` is advisory only.
#
# Before evaluating thresholds it binds the input to the EXACT genuine snapshot contract and enforces
# every recorder conservation law. A forged/malformed snapshot fails closed to hold/invalid_snapshot;
# an arithmetically impossible counter set fails closed to hold/inconsistent_counters.
#
# MUTATION PROOF (Gap 4): the runtime metrics snapshot deliberately carries NO self-declared
# mutation count — a store could never truthfully MEASURE reply/state mutation, so it must not claim
# it, and a forged snapshot must not be able to assert zero. Instead this gate requires a SEPARATELY
# SUPPLIED, independently-validated `mutation_proof` artifact (produced only by the deterministic
# Evaluator that genuinely observes every run). A missing/malformed proof fails closed to
# hold/mutation_proof_missing; a proof that itself reports an observed mutation fails closed to
# hold/mutation_detected. So a forged runtime snapshot alone can never reach eligible.
class Marine::ProductAuthority::ShadowAcceptance
  Store = Marine::ProductAuthority::ShadowMetricsStore
  Outcome = Marine::ProductAuthority::ProductOutcome

  SCHEMA_VERSION = 'marine_product_authority_shadow_acceptance_v1'.freeze

  # Conservative production constants.
  MIN_TOTAL = 50
  MIN_COMPARABLE = 30
  BASIS = 10_000
  MIN_EXACT_AGREEMENT_BPS = 8_000       # 80%
  MAX_CANDIDATE_BLOCKED_BPS = 2_000     # 20%

  STATUS_INSUFFICIENT = 'insufficient_data'.freeze
  STATUS_HOLD = 'hold'.freeze
  STATUS_ELIGIBLE = 'eligible_for_review'.freeze

  # The EXACT top-level key set a genuine ShadowMetricsStore ok-snapshot carries. There is deliberately
  # NO `mutations` field — mutation-cleanliness is proven by the separate `mutation_proof` artifact.
  EXPECTED_SNAPSHOT_KEYS = %i[schema_version ok account_id assistant_id days counters].freeze

  # The separately-supplied, independently-validated mutation-proof artifact contract (produced by the
  # Evaluator that genuinely observes every run). Nothing else may assert mutation-cleanliness.
  MUTATION_PROOF_SCHEMA = 'marine_product_authority_mutation_proof_v1'.freeze
  MUTATION_PROOF_KEYS = %i[schema_version source runs mutation_observed].freeze

  def self.evaluate(snapshot, mutation_proof: nil)
    new.evaluate(snapshot, mutation_proof: mutation_proof)
  end

  # A deep-frozen advisory report for the given snapshot + external mutation proof. Never raises.
  def evaluate(snapshot, mutation_proof: nil)
    counts = counts_from(snapshot)
    return report(STATUS_HOLD, 'invalid_snapshot', nil) if counts.nil?

    mutation_hold = mutation_hold_reason(mutation_proof)
    return report(STATUS_HOLD, mutation_hold, counts) if mutation_hold
    return report(STATUS_HOLD, 'inconsistent_counters', counts) unless consistent?(counts)
    return report(STATUS_INSUFFICIENT, insufficient_reason(counts), counts) if insufficient?(counts)

    hold = hold_reason(counts)
    return report(STATUS_HOLD, hold, counts) if hold

    report(STATUS_ELIGIBLE, 'thresholds_met', counts)
  rescue StandardError
    report(STATUS_HOLD, 'invalid_snapshot', nil)
  end

  private

  # The mutation-gate hold reason, or nil when the supplied proof is a genuine zero-mutation artifact.
  # A proof claiming an observed mutation is a positive delta; a missing/malformed proof fails closed.
  def mutation_hold_reason(proof)
    return 'mutation_detected' if mutation_claimed?(proof)
    return 'mutation_proof_missing' unless valid_mutation_proof?(proof)

    nil
  end

  # A proof that itself reports an observed mutation is a positive delta and fails closed, even if
  # otherwise well-formed.
  def mutation_claimed?(proof)
    proof.is_a?(Hash) && proof[:mutation_observed] == true
  end

  # The mutation proof must be EXACTLY the evaluator-produced artifact: exact keys, the exact schema
  # version, the evaluator source, a positive observed-run count, and a false mutation observation.
  def valid_mutation_proof?(proof)
    proof.is_a?(Hash) &&
      proof.keys.sort == MUTATION_PROOF_KEYS.sort &&
      proof[:schema_version] == MUTATION_PROOF_SCHEMA &&
      proof[:source] == 'evaluator' &&
      proof[:runs].is_a?(Integer) && proof[:runs].positive? &&
      proof[:mutation_observed] == false
  end

  def counts_from(snapshot)
    return nil unless genuine_snapshot?(snapshot)

    aggregate(snapshot[:counters])
  end

  def aggregate(counters)
    total = count(counters, 'total')
    {
      total: total,
      comparable: count(counters, 'comparable'),
      exact_agreement: count(counters, 'exact_agreement')
    }.merge(status_family_counts(counters, total)).merge(matrix_count(counters))
  end

  def status_family_counts(counters, _total)
    {
      legacy_status_sum: sum_fields(counters, status_fields('legacy_status')),
      candidate_status_sum: sum_fields(counters, status_fields('candidate_status')),
      candidate_blocked: count(counters, "candidate_status.#{Outcome::STATUS_BLOCKED}")
    }
  end

  def matrix_count(counters)
    { matrix_sum: prefix_values(counters, 'matrix.').sum }
  end

  # The snapshot must be EXACTLY a genuine ShadowMetricsStore ok-snapshot: same schema version, ok
  # true, positive integer ids, integer days within the retention window, the exact top-level key
  # set, and a Hash of counters. Mutation-cleanliness is proven separately by `mutation_proof`.
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

  def prefix_values(counters, prefix)
    counters.keys.select { |field| field.is_a?(String) && field.start_with?(prefix) }
            .map { |field| count(counters, field) }
  end

  def sum_fields(counters, fields)
    fields.sum { |field| count(counters, field) }
  end

  def status_fields(prefix)
    Outcome::STATUSES.map { |status| "#{prefix}.#{status}" }
  end

  # Every recorder conservation law a genuine snapshot must satisfy, enforced BEFORE any threshold
  # evaluation. A single violation fails the snapshot closed to hold/inconsistent_counters.
  def consistent?(counts)
    counts[:legacy_status_sum] == counts[:total] &&
      counts[:candidate_status_sum] == counts[:total] &&
      counts[:comparable] <= counts[:total] &&
      counts[:exact_agreement] <= counts[:comparable] &&
      counts[:candidate_blocked] <= counts[:total] &&
      counts[:matrix_sum] == counts[:comparable]
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
    return 'exact_agreement_below_threshold' if counts[:exact_agreement] * BASIS < MIN_EXACT_AGREEMENT_BPS * counts[:comparable]
    return 'candidate_blocked_rate_exceeded' if counts[:candidate_blocked] * BASIS > MAX_CANDIDATE_BLOCKED_BPS * counts[:total]

    nil
  end

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

    { total: counts[:total], comparable: counts[:comparable],
      exact_agreement: counts[:exact_agreement], candidate_blocked: counts[:candidate_blocked] }
  end

  def rates(counts)
    return {} if counts.nil?

    { exact_agreement: rate_bps(counts[:exact_agreement], counts[:comparable]),
      candidate_blocked: rate_bps(counts[:candidate_blocked], counts[:total]) }
  end

  def thresholds
    { min_total: MIN_TOTAL, min_comparable: MIN_COMPARABLE,
      min_exact_agreement_bps: MIN_EXACT_AGREEMENT_BPS, max_candidate_blocked_bps: MAX_CANDIDATE_BLOCKED_BPS }
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end
end
