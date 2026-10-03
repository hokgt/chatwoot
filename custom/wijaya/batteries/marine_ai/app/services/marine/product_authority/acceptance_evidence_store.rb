require 'json'

# Fase 3A-2c — Battery-local, BOUNDED, DETERMINISTIC, in-Redis retention of ONE acceptance RUN's
# evidence for audit, following the Marine::ProductAuthority::ShadowMetricsStore precedent (versioned
# key namespace, closed field set, integer/enum/boolean/JSON-of-closed-codes only, TTL, fail-closed,
# no SCAN/KEYS/destructive reset). It projects an acceptance run — per RUN, never per case forever —
# to a single Redis hash and keeps a bounded FIFO index of retained run ids.
#
#   hash  : marine:product_authority:acceptance:evidence:v1:<run_id>
#   index : marine:product_authority:acceptance:evidence:v1:index   (newest-first, <= MAX_RUNS ids)
#
# WHAT IS RETAINED (closed, bounded projection ONLY):
#   * meta        — schema_version, created_at (integer epoch from the INJECTED clock), run_kind
#                   ('evaluator' | 'runner' | 'parity'), case_count.
#   * aggregate   — ONLY the aggregate report's INTEGER/BOOLEAN scalar fields (counts, rates, flags),
#                   plus its own schema_version; arrays (failures, case_evidence, …) are dropped.
#   * mutation    — the mutation-proof projected to its closed { schema_version, source, runs,
#                   mutation_observed } fields, or the explicit 'mutation_proof_missing' marker (so the
#                   audit trail shows a readiness-relevant ABSENCE instead of silently omitting it).
#   * cases       — one bounded row per case carrying ONLY AcceptanceCaseResult's closed #to_h FIELDS
#                   (re-projected against a LOCAL closed allowlist). NO plan payloads, repository
#                   fixtures, synthetic message text, prompts, or exception/DB detail are ever stored.
#
# CORRELATION: the caller-supplied run_id IS the correlation key (the aggregate reports carry no run
# identifier today). BOUNDS: at most MAX_RUNS run ids are indexed (deterministic FIFO eviction via
# LREM+LPUSH+LTRIM); each run hash carries a TTL_DAYS TTL. An evicted run_id's hash is NOT actively
# deleted — its TTL reclaims it. MAX_RUNS and TTL_DAYS are TECHNICAL bounds that mirror the shadow
# metrics precedent; they are subject to human data-retention-policy confirmation.
#
# It is acceptance-only audit plumbing: NOT wired into any live runtime path, stores NO raw plans/text/
# prompts/customer data, exposes NO delete/reset method, and leaves CandidateGate phase-locked.
class Marine::ProductAuthority::AcceptanceEvidenceStore
  SCHEMA_VERSION = 'marine_product_authority_acceptance_evidence_v1'.freeze
  KEY_PREFIX = 'marine:product_authority:acceptance:evidence:v1'.freeze
  INDEX_KEY = "#{KEY_PREFIX}:index".freeze

  # Technical retention bounds, mirroring ShadowMetricsStore's 14-day precedent (human
  # data-retention-policy confirmation pending).
  TTL_DAYS = 14
  TTL_SECONDS = TTL_DAYS * 24 * 60 * 60
  MAX_RUNS = 200
  # Defensive ceiling on the per-run case rows a single save may carry (corpus is tiny; a larger set
  # signals a hostile/corrupted input and fails the save closed).
  MAX_CASE_ROWS = 512
  MAX_STRING = 128

  # A bounded, safe run id: it carries no customer data and fits one Redis key segment.
  RUN_ID_PATTERN = /\A[A-Za-z0-9_.\-]{1,64}\z/

  # The closed run kinds a retained run may declare.
  RUN_KINDS = %w[evaluator runner parity].freeze

  # The explicit absence marker for a run saved without a mutation proof (readiness-relevant).
  MUTATION_PROOF_MISSING = 'mutation_proof_missing'.freeze

  # LOCAL closed allowlist of the AcceptanceCaseResult #to_h keys a row may carry (defense in depth over
  # #to_h). Only these are projected; expected_outcome / actual_outcome are themselves already-closed
  # nested code hashes and are kept as-is.
  CASE_ROW_KEYS = %i[schema_version case_id surface candidate_plan_status exact_quantity_status
                     adapter_status planner_status repository_revalidation_status evidence_packet_status
                     expected_outcome actual_outcome reason passed].freeze

  # The closed set of aggregate scalar fields retained — INTEGER or BOOLEAN only, across both the
  # runner (marine_product_authority_acceptance_run_v1) and parity
  # (marine_product_authority_parity_run_v1) aggregate shapes. Anything else (arrays, nested evidence)
  # is dropped so no raw data can ride along.
  AGGREGATE_SCALAR_KEYS = %i[total_executed passed failed not_executed all_evaluated
                             total_cases executed parity_ok_count reason_divergence_count
                             both_passed_count].freeze

  # The closed projected mutation-proof fields (the mutation_proof_v1 contract shape).
  PROOF_KEYS = %i[schema_version source runs mutation_observed].freeze

  # A deterministic default clock; callers inject the evaluation's FIXED_CLOCK for reproducibility.
  DEFAULT_CLOCK = -> { Time.current }

  # rubocop:disable Metrics/ParameterLists -- a deliberately explicit keyword audit API
  def self.save(run_id:, kind:, aggregate:, case_results:, mutation_proof: nil, clock: DEFAULT_CLOCK, redis: nil, now: nil)
    new.save(run_id: run_id, kind: kind, aggregate: aggregate, case_results: case_results,
             mutation_proof: mutation_proof, clock: clock, redis: redis, now: now)
  end
  # rubocop:enable Metrics/ParameterLists

  def self.fetch(run_id:, redis: nil)
    new.fetch(run_id: run_id, redis: redis)
  end

  def self.fetch_index(limit: 50, redis: nil)
    new.fetch_index(limit: limit, redis: redis)
  end

  # Retain ONE run's bounded projection. Returns true on a genuine write, false on ANY validation
  # failure or Redis error (fail-closed, never raises). An idempotent re-save of the same run_id
  # overwrites the fixed hash-field set deterministically and refreshes the TTL.
  # rubocop:disable Metrics/ParameterLists -- a deliberately explicit keyword audit API
  def save(run_id:, kind:, aggregate:, case_results:, mutation_proof: nil, clock: DEFAULT_CLOCK, redis: nil, now: nil)
    return false unless valid_inputs?(run_id, kind, aggregate, case_results)

    fields = build_fields(run_id, kind, aggregate, mutation_proof, case_results, epoch(now, clock))
    return false if fields.nil?

    persist(run_id, fields, redis)
    true
  rescue StandardError
    false
  end
  # rubocop:enable Metrics/ParameterLists

  # A deep-frozen projection of the retained run, or nil on a missing / malformed / wrong-schema hash
  # or any read error (fail-closed).
  def fetch(run_id:, redis: nil)
    return nil unless valid_run_id?(run_id)

    raw = read_hash(run_key(run_id), redis)
    return nil unless raw.is_a?(Hash) && raw['schema_version'] == SCHEMA_VERSION

    project_fetch(run_id, raw)
  rescue StandardError
    nil
  end

  # The bounded list of retained run ids, newest first (for audit listing). Fail-closed to [].
  def fetch_index(limit: 50, redis: nil)
    return [] unless limit.is_a?(Integer) && limit.positive?

    ids = read_index(limit, redis)
    return [] unless ids.is_a?(Array)

    ids.select { |id| valid_run_id?(id) }
  rescue StandardError
    []
  end

  private

  def valid_inputs?(run_id, kind, aggregate, case_results)
    valid_run_id?(run_id) && RUN_KINDS.include?(kind) && aggregate.is_a?(Hash) &&
      case_results.is_a?(Array) && case_results.length <= MAX_CASE_ROWS
  end

  # --- write path -----------------------------------------------------------------------

  # The fixed, closed hash-field set for one run, or nil when a projection fails closed (e.g. a case
  # result that cannot be projected to its closed row). Every field is a String, an integer-as-String,
  # or a JSON encoding of an already-closed structure.
  def build_fields(run_id, kind, aggregate, mutation_proof, case_results, created_at) # rubocop:disable Metrics/ParameterLists
    rows = project_case_rows(case_results)
    return nil if rows.nil?

    {
      'schema_version' => SCHEMA_VERSION,
      'run_id' => run_id,
      'created_at' => created_at.to_s,
      'run_kind' => kind,
      'aggregate_schema_version' => bounded_string(aggregate[:schema_version]),
      'aggregate' => JSON.generate(project_aggregate(aggregate)),
      'mutation_proof' => project_proof(mutation_proof),
      'case_count' => rows.length.to_s,
      'cases' => JSON.generate(rows)
    }
  end

  # ONLY the aggregate's integer/boolean scalar fields survive; arrays and nested evidence are dropped.
  def project_aggregate(aggregate)
    AGGREGATE_SCALAR_KEYS.each_with_object({}) do |key, acc|
      value = aggregate[key]
      acc[key] = value if value.is_a?(Integer) || value == true || value == false
    end
  end

  # The mutation proof projected to its closed fields, or the explicit absence marker when no proof is
  # supplied (so the audit shows readiness-relevant absence rather than silently omitting it).
  def project_proof(mutation_proof)
    return MUTATION_PROOF_MISSING unless mutation_proof.is_a?(Hash)

    JSON.generate(
      schema_version: bounded_string(mutation_proof[:schema_version]),
      source: bounded_string(mutation_proof[:source]),
      runs: mutation_proof[:runs].is_a?(Integer) ? mutation_proof[:runs] : nil,
      mutation_observed: [true, false].include?(mutation_proof[:mutation_observed]) ? mutation_proof[:mutation_observed] : nil
    )
  end

  # One bounded row per case, each carrying ONLY the closed CASE_ROW_KEYS from the result's #to_h. Any
  # result that cannot be projected (no #to_h / non-Hash) fails the whole save closed (nil).
  def project_case_rows(case_results)
    case_results.map { |result| project_case_row(result) }
  rescue StandardError
    nil
  end

  def project_case_row(result)
    raw = result.to_h
    raise ArgumentError unless raw.is_a?(Hash)

    CASE_ROW_KEYS.index_with { |key| raw[key] }
  end

  # Overwrite the run hash + TTL and move the run_id to the head of the bounded index in ONE MULTI.
  # LREM dedupes a re-saved id; LPUSH makes it newest; LTRIM evicts the oldest beyond MAX_RUNS.
  def persist(run_id, fields, redis)
    key = run_key(run_id)
    with_redis(redis) do |conn|
      conn.multi do |transaction|
        transaction.hset(key, fields)
        transaction.expire(key, TTL_SECONDS)
        transaction.lrem(INDEX_KEY, 0, run_id)
        transaction.lpush(INDEX_KEY, run_id)
        transaction.ltrim(INDEX_KEY, 0, MAX_RUNS - 1)
      end
    end
  end

  # --- read path ------------------------------------------------------------------------

  def project_fetch(run_id, raw)
    created_at = integer_value(raw['created_at'])
    kind = raw['run_kind']
    return nil if created_at.nil? || RUN_KINDS.exclude?(kind)

    deep_freeze(
      schema_version: SCHEMA_VERSION,
      run_id: run_id,
      created_at: created_at,
      run_kind: kind,
      aggregate_schema_version: raw['aggregate_schema_version'].to_s,
      aggregate: JSON.parse(raw['aggregate'].to_s, symbolize_names: true),
      mutation_proof: parse_proof(raw['mutation_proof']),
      case_count: integer_value(raw['case_count']) || 0,
      cases: JSON.parse(raw['cases'].to_s, symbolize_names: true)
    )
  end

  def parse_proof(value)
    return MUTATION_PROOF_MISSING if value == MUTATION_PROOF_MISSING

    parsed = JSON.parse(value.to_s, symbolize_names: true)
    raise ArgumentError unless parsed.is_a?(Hash)

    PROOF_KEYS.index_with { |key| parsed[key] }
  end

  def read_hash(key, redis)
    with_redis(redis) { |conn| conn.hgetall(key) }
  end

  def read_index(limit, redis)
    with_redis(redis) { |conn| conn.lrange(INDEX_KEY, 0, limit - 1) }
  end

  # --- helpers --------------------------------------------------------------------------

  # Use an injected Redis connection when supplied (test/operator seam), else the shared Alfred pool.
  def with_redis(redis, &)
    return yield(redis) if redis

    Redis::Alfred.with(&)
  end

  def epoch(now, clock)
    base = now || clock.call
    Integer(base.to_i)
  end

  def valid_run_id?(value)
    value.is_a?(String) && value.match?(RUN_ID_PATTERN)
  end

  def run_key(run_id)
    "#{KEY_PREFIX}:#{run_id}"
  end

  def bounded_string(value)
    return '' unless value.is_a?(String)

    value[0, MAX_STRING]
  end

  def integer_value(value)
    return value if value.is_a?(Integer) && !value.negative?
    return nil unless value.is_a?(String) && value.match?(/\A\d+\z/)

    Integer(value, 10)
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end
end
