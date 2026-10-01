# Fase 3A-2 — DETERMINISTIC, ADVISORY evaluator for the product-authority corpus. It folds every
# synthetic labelled case through the REAL Fase 3A-1 pipeline —
# Marine::Backend::CandidatePlanToProductIntentAdapter then Marine::Backend::ProductExecutionPlanner —
# with the case's INJECTED read-only repository fixtures (the repository revalidation), projects the
# result through ProductOutcome, and scores it against the backend-owned label. Legacy output is never
# consulted; the labels are the acceptance truth.
#
# It first validates the corpus SCHEMA fail-closed and CLOSED (a malformed, unknown-keyed, duplicate,
# out-of-vocabulary, or oversized case fails the WHOLE run closed) and enforces result conservation
# laws. Three safety harnesses run inside the evaluation and never touch live runtime authority:
#
#   * Exact-quantity guard (Gap 2): a case carrying `safety.exact_quantity_request` is short-circuited
#     to a safe blocked/handoff outcome BEFORE any adapter/planner/stock execution, proving the
#     pre-existing backend-owned no-exact-quantity policy holds even when the plan + fixtures would
#     otherwise resolve to a normal stock answer.
#   * Surface-aware parity (Gap 3): a `parity: true` case is folded through TWO independently-declared
#     bounded surface adapters (Conversation and Playground) that normalize distinct surface-native
#     envelopes into the SAME canonical backend input; parity holds only when their adapter+planner
#     fingerprints are equal.
#   * Measured mutation evidence (Gap 4): an injected MutationProbe observes every repository read, and
#     `mutation_capability` is a structural property of the read-only repository fakes. The report
#     carries MEASURED `mutation_observed` (never a hardcoded 0) plus, when the run is genuinely clean,
#     a validated `mutation_proof` artifact ShadowAcceptance requires. Policy fails closed unless the
#     observer actually reported zero mutation for every run.
#
# It reports the fixed acceptance policy — critical safety 100%, overall supported-intent accuracy
# >=95%, valid slot-operation schema + repository revalidation 100%, Conversation/Playground parity,
# and measured zero mutation — as an ADVISORY result ONLY. It NEVER mutates config, enables a switch,
# calls a provider, or activates anything automatically, and performs NO settings/Redis access. It is
# not wired into any runtime hook/job; it is invoked only by a spec or an operator review.
# rubocop:disable Metrics/ClassLength -- one cohesive advisory scorer: closed schema validation, the
# three safety harnesses, adapter+planner folding, and the acceptance policy belong to one seam.
class Marine::ProductAuthority::Evaluator
  Corpus = Marine::ProductAuthority::Corpus
  Outcome = Marine::ProductAuthority::ProductOutcome
  Adapter = Marine::Backend::CandidatePlanToProductIntentAdapter
  Planner = Marine::Backend::ProductExecutionPlanner
  Acceptance = Marine::ProductAuthority::ShadowAcceptance
  CatalogUnavailable = Marine::Catalog::Errors::CatalogUnavailableError

  SCHEMA_VERSION = 'marine_product_authority_evaluator_v1'.freeze

  # A fixed clock so a price fact's checked_at is deterministic (never Time.current), keeping the
  # evaluation reproducible and side-effect-free.
  FIXED_CLOCK = -> { Time.utc(2026, 1, 1) }

  # The exact REQUIRED key set every corpus case must carry, the explicitly-optional case keys, and
  # the exact required + optional label key sets. A case/label carrying any key outside these sets
  # fails the schema closed.
  CASE_KEYS = %i[id category critical surface scenario_key capabilities plan repositories label].freeze
  OPTIONAL_CASE_KEYS = %i[safety parity].freeze
  LABEL_KEYS = %i[status intents slot_ops response_goals].freeze
  OPTIONAL_LABEL_KEYS = %i[block_reason].freeze

  # Closed response-goal vocabulary (the planner's goal allowlist) a label may reference.
  RESPONSE_GOALS = %w[answer_price answer_stock answer_product_overview clarify_product clarify_variant
                      clarify_ambiguous_variant handoff].freeze

  # Closed block-reason vocabulary: the adapter's allowlisted fail-closed reasons plus the
  # evaluator-owned exact-quantity safety reason.
  EXACT_QUANTITY_REASON = 'exact_quantity_request'.freeze
  ADAPTER_BLOCK_REASONS = %w[unsupported_schema unresolved_scenario scenario_mismatch capability_unconfigured
                             capability_malformed capability_mismatch unsupported_intent].freeze
  BLOCK_REASONS = (ADAPTER_BLOCK_REASONS + [EXACT_QUANTITY_REASON]).freeze

  # Defensive ceilings so a hostile/oversized case fails the schema closed rather than blowing up.
  MAX_STRING = 128
  MAX_COLLECTION = 64
  SURFACES_ALLOWED = %w[conversation playground both].freeze
  REPOSITORY_KEYS = %i[family variant price stock].freeze

  # Write-shaped methods a read-only repository fake must never expose (structural mutation capability).
  WRITE_METHOD_DENYLIST = %i[save save! update update! create create! destroy destroy! delete delete!
                             write insert []= push << increment decrement upsert].freeze

  def self.evaluate(cases = Corpus.cases, surfaces: nil, mutation_probe: nil)
    new.evaluate(cases, surfaces: surfaces, mutation_probe: mutation_probe)
  end

  # A deep-frozen advisory report over the given cases. Never raises. `surfaces` and `mutation_probe`
  # are injectable for tests; production callers use the deterministic defaults.
  def evaluate(cases = Corpus.cases, surfaces: nil, mutation_probe: nil)
    error = corpus_error(cases)
    return invalid_report(error) if error

    probe = mutation_probe || MutationProbe.new
    surface_adapters = surfaces || SURFACES
    results = cases.map { |kase| score(kase, surface_adapters, probe) }
    aggregate(results, probe)
  rescue StandardError
    invalid_report('evaluation_error')
  end

  private

  # --- schema validation (fail-closed, CLOSED key sets) ---------------------------------

  # The first corpus-level failure reason, or nil when the whole corpus is well-formed.
  def corpus_error(cases)
    return 'invalid_corpus' unless cases.is_a?(Array) && !cases.empty?
    return 'duplicate_ids' unless unique_ids?(cases)
    return 'schema_invalid' unless cases.all? { |kase| valid_case?(kase) }

    nil
  end

  def unique_ids?(cases)
    ids = cases.map { |kase| kase.is_a?(Hash) ? kase[:id] : nil }
    ids.all?(String) && ids.uniq.length == ids.length
  end

  def valid_case?(kase)
    kase.is_a?(Hash) &&
      closed_keys?(kase, CASE_KEYS, OPTIONAL_CASE_KEYS) &&
      valid_case_scalars?(kase) && valid_case_structure?(kase)
  end

  def valid_case_scalars?(kase)
    bounded_string?(kase[:id]) && bounded_string?(kase[:category]) &&
      [true, false].include?(kase[:critical]) &&
      SURFACES_ALLOWED.include?(kase[:surface]) &&
      bounded_string?(kase[:scenario_key])
  end

  def valid_case_structure?(kase)
    valid_capabilities?(kase[:capabilities]) &&
      kase[:plan].is_a?(Hash) && valid_repositories?(kase[:repositories]) &&
      valid_optional_metadata?(kase) && valid_label?(kase[:label])
  end

  # Exactly the required keys, and nothing outside required + optional.
  def closed_keys?(hash, required, optional)
    keys = hash.keys
    (required - keys).empty? && (keys - required - optional).empty?
  end

  def valid_capabilities?(capabilities)
    capabilities.is_a?(Hash) && capabilities.size <= MAX_COLLECTION &&
      capabilities.all? { |key, intents| valid_capability_entry?(key, intents) }
  end

  def valid_capability_entry?(key, intents)
    bounded_string?(key) && intents.is_a?(Array) && intents.length <= MAX_COLLECTION &&
      intents.all? { |intent| bounded_string?(intent) }
  end

  # A repositories fixture must be a Hash whose keys are a subset of the closed repository set and whose
  # every value is a Hash (a bounded injected map). A malformed shape fails closed.
  def valid_repositories?(repositories)
    repositories.is_a?(Hash) &&
      (repositories.keys - REPOSITORY_KEYS).empty? &&
      repositories.values.all? { |value| value.is_a?(Hash) && value.size <= MAX_COLLECTION }
  end

  def valid_optional_metadata?(kase)
    valid_safety?(kase[:safety]) && (!kase.key?(:parity) || [true, false].include?(kase[:parity]))
  end

  # The optional safety metadata is a bounded { exact_quantity_request: Boolean } map or absent.
  def valid_safety?(safety)
    return true if safety.nil?

    safety.is_a?(Hash) && safety.keys == %i[exact_quantity_request] &&
      [true, false].include?(safety[:exact_quantity_request])
  end

  def valid_label?(label)
    return false unless label.is_a?(Hash)
    return false unless closed_keys?(label, LABEL_KEYS, OPTIONAL_LABEL_KEYS)
    return false unless Outcome::STATUSES.include?(label[:status])
    return false unless closed_codes?(label[:intents], Outcome::INTENTS)
    return false unless closed_codes?(label[:slot_ops], Outcome::SLOT_OPS)
    return false unless valid_response_goals?(label[:response_goals])

    valid_block_reason?(label)
  end

  # A closed, deduplicated, bounded code list drawn only from `allowed`.
  def closed_codes?(value, allowed)
    value.is_a?(Array) && value.length <= allowed.length &&
      value.all? { |code| allowed.include?(code) } &&
      value.uniq.length == value.length
  end

  def valid_response_goals?(goals)
    return true if goals.nil?

    closed_codes?(goals, RESPONSE_GOALS)
  end

  # A block_reason may appear ONLY on a blocked label, and only from the closed vocabulary.
  def valid_block_reason?(label)
    return true unless label.key?(:block_reason)

    label[:status] == Outcome::STATUS_BLOCKED && BLOCK_REASONS.include?(label[:block_reason])
  end

  def bounded_string?(value)
    value.is_a?(String) && !value.empty? && value.length <= MAX_STRING
  end

  # --- per-case scoring -----------------------------------------------------------------

  # A frozen per-case result: whether it passed, and the classification flags the aggregate needs.
  # `parity_ok` is nil for non-parity cases and a boolean for parity cases (cross-surface agreement).
  Result = Struct.new(:id, :passed, :critical, :supported, :blocked, :planner_ran, :parity_ok, keyword_init: true)

  def score(kase, surfaces, probe)
    probe.note_run
    return score_exact_quantity(kase) if exact_quantity_guarded?(kase)
    return score_parity(kase, surfaces, probe) if kase[:parity]

    run = run_single(kase, kase[:plan], kase[:scenario_key], kase[:capabilities], probe)
    build_result(kase, passed: run[:passed], blocked: run[:blocked], planner_ran: run[:planner_ran], parity_ok: nil)
  rescue StandardError
    failed_result(kase, planner_ran: false)
  end

  def exact_quantity_guarded?(kase)
    kase[:safety].is_a?(Hash) && kase[:safety][:exact_quantity_request] == true
  end

  # Gap 2 — enforce the pre-existing no-exact-quantity policy BEFORE any adapter/planner/stock work.
  # The adapter and planner are NEVER constructed for this case (proving the stock repository does not
  # run); the label must expect a safe blocked/handoff outcome with the exact-quantity reason.
  def score_exact_quantity(kase)
    label = kase[:label]
    passed = label[:status] == Outcome::STATUS_BLOCKED && label[:block_reason] == EXACT_QUANTITY_REASON
    build_result(kase, passed: passed, blocked: true, planner_ran: false, parity_ok: nil)
  end

  # Gap 3 — fold the ONE turn through both surface adapters; parity holds only when their adapter+planner
  # fingerprints are identical AND each surface independently matches the label.
  def score_parity(kase, surfaces, probe)
    turn = { plan: kase[:plan], scenario_key: kase[:scenario_key], capabilities: kase[:capabilities] }
    runs = surfaces.map do |surface|
      input = surface.adapt(turn)
      run_single(kase, input[:plan], input[:scenario_key], input[:capabilities], probe)
    end
    parity_ok = runs.pluck(:fingerprint).uniq.length == 1
    build_result(
      kase, passed: parity_ok && runs.all? { |run| run[:passed] },
            blocked: runs.first[:blocked], planner_ran: runs.all? { |run| run[:planner_ran] }, parity_ok: parity_ok
    )
  end

  # Fold one bounded backend input through the adapter and (when accepted) the planner, and score it
  # against the label. Returns the pass flag, the blocked/planner flags, and the outcome+goals
  # fingerprint the parity harness compares.
  def run_single(kase, plan, scenario_key, capabilities, probe)
    label = kase[:label]
    adapter_result = Adapter.new.call(plan: plan, scenario_key: scenario_key, scenario_capabilities: capabilities)
    return run_blocked(label, adapter_result) unless adapter_result.ok?

    outcome = Outcome.project(adapter_result.product_intent)
    goals = run_planner(kase, adapter_result, probe)
    passed = label[:status] != Outcome::STATUS_BLOCKED &&
             outcome_matches?(outcome, label) && goals_match?(goals, label[:response_goals])
    { passed: passed, blocked: false, planner_ran: true, fingerprint: [outcome, goals&.sort] }
  end

  def run_blocked(label, adapter_result)
    passed = label[:status] == Outcome::STATUS_BLOCKED && label[:block_reason] == adapter_result.reason
    { passed: passed, blocked: true, planner_ran: false, fingerprint: [Outcome.blocked, adapter_result.reason] }
  end

  # Run the planner with the case's injected fixtures (threaded through the mutation probe) and return
  # its deduped response goals, or nil on any planner/repository error (a nil never matches a non-nil
  # label, so the case fails closed).
  def run_planner(kase, adapter_result, probe)
    evidence = Planner.new(**planner_repositories(kase, probe)).call(
      product_intent: adapter_result.product_intent,
      intents: adapter_result.intents,
      scenario: adapter_result.scenario
    )
    evidence[:response_goals]
  rescue StandardError
    nil
  end

  def planner_repositories(kase, probe)
    repos = kase[:repositories]
    {
      family_repository: FakeFamilyRepository.new(repos[:family] || {}, probe),
      variant_resolver: FakeVariantResolver.new(repos[:variant] || {}, probe),
      price_repository: FakePriceRepository.new(repos[:price] || {}, probe),
      stock_repository: FakeStockRepository.new(repos[:stock] || {}, probe),
      price_formatter: FakePriceFormatter.new,
      clock: FIXED_CLOCK
    }
  end

  def outcome_matches?(outcome, label)
    outcome[:status] == label[:status] &&
      outcome[:intents] == label[:intents] &&
      outcome[:slot_ops] == label[:slot_ops]
  end

  # Order-independent goal comparison; nil-vs-nil matches, nil-vs-list does not.
  def goals_match?(goals, expected)
    return goals.nil? if expected.nil?
    return false if goals.nil?

    goals.sort == expected.sort
  end

  def build_result(kase, passed:, blocked:, planner_ran:, parity_ok:)
    Result.new(
      id: kase[:id], passed: passed, critical: kase[:critical],
      supported: !blocked && kase[:label][:status] != Outcome::STATUS_BLOCKED,
      blocked: blocked, planner_ran: planner_ran, parity_ok: parity_ok
    ).freeze
  end

  def failed_result(kase, planner_ran:)
    Result.new(
      id: kase[:id], passed: false, critical: kase[:critical],
      supported: kase[:label][:status] != Outcome::STATUS_BLOCKED, blocked: false,
      planner_ran: planner_ran, parity_ok: (kase[:parity] ? false : nil)
    ).freeze
  end

  # --- aggregation + acceptance policy --------------------------------------------------

  def aggregate(results, probe)
    counts = build_counts(results, probe)
    # Conservation laws: a violation is impossible by construction and fails the run closed.
    return invalid_report('inconsistent_results') if counts.nil?

    report(counts, results)
  end

  # A flat set of bounded integer tallies plus the measured mutation evidence, or nil when a
  # conservation law is violated.
  def build_counts(results, probe)
    total = results.length
    criticals = results.select(&:critical)
    supported = results.select(&:supported)
    return nil unless conservation_ok?(total, results.count(&:passed), criticals, supported)

    tally(results, criticals, supported).merge(mutation_counts(probe, total))
  end

  def tally(results, criticals, supported)
    {
      total: results.length, passed: results.count(&:passed),
      critical_total: criticals.length, critical_passed: criticals.count(&:passed),
      supported_total: supported.length, supported_passed: supported.count(&:passed),
      # Repository revalidation: every supported (non-blocked) case must have reached and invoked the
      # planner against the injected read-only repositories (planner_ran). planner_ran is false only
      # when scoring failed BEFORE the planner was invoked (the adapter raised, or score rescued). A
      # planner/repository error INSIDE the invocation is swallowed to nil goals — the case still
      # revalidated and fails instead on the goal mismatch.
      repo_revalidation_ok: supported.all?(&:planner_ran),
      schema_valid: true, parity_ok: parity_ok?(results)
    }
  end

  # Gap 4 — MEASURED, never a hardcoded literal: the probe observed every run and reported zero
  # mutations, and the read-only fakes structurally expose no write method.
  def mutation_counts(probe, total)
    {
      mutation_observed: probe.mutations.positive?,
      mutation_capability: structural_mutation_capability,
      observer_ok: probe.runs >= total && probe.runs.positive?,
      runs: probe.runs
    }
  end

  def conservation_ok?(total, passed, criticals, supported)
    passed <= total &&
      criticals.count(&:passed) <= criticals.length &&
      supported.count(&:passed) <= supported.length
  end

  # Every parity case must have produced identical cross-surface fingerprints (parity_ok) and passed.
  # No parity case => trivially ok.
  def parity_ok?(results)
    parity_results = results.reject { |result| result.parity_ok.nil? }
    parity_results.all? { |result| result.parity_ok && result.passed }
  end

  # Structural mutation capability of the injected repository fakes: :none when no fake exposes any
  # write-shaped method, :present otherwise. This is a truthful structural property, not a claim.
  def structural_mutation_capability
    writable = [FakeFamilyRepository, FakeVariantResolver, FakePriceRepository, FakeStockRepository, FakePriceFormatter]
               .any? { |klass| klass.public_instance_methods(false).intersect?(WRITE_METHOD_DENYLIST) }
    writable ? :present : :none
  end

  # The run is mutation-clean ONLY when the injected observer actually observed every run, reported
  # zero mutations, and the fakes structurally cannot mutate. Missing observer evidence fails closed.
  def mutation_clean?(counts)
    counts[:observer_ok] && !counts[:mutation_observed] && counts[:mutation_capability] == :none
  end

  def report(counts, results)
    supported_bps = rate_bps(counts[:supported_passed], counts[:supported_total])
    critical_bps = rate_bps(counts[:critical_passed], counts[:critical_total])
    deep_freeze(
      schema_version: SCHEMA_VERSION,
      ok: true,
      mutation_observed: counts[:mutation_observed],
      mutation_capability: counts[:mutation_capability].to_s,
      mutation_proof: mutation_proof(counts),
      counts: counts.merge(mutation_capability: counts[:mutation_capability].to_s),
      rates_bps: { supported_accuracy: supported_bps, critical_accuracy: critical_bps },
      thresholds: {
        min_supported_accuracy_bps: Corpus::MIN_SUPPORTED_ACCURACY_BPS,
        critical_accuracy_bps: Corpus::CRITICAL_ACCURACY_BPS,
        schema_valid_bps: Corpus::SCHEMA_VALID_BPS
      },
      meets_policy: meets_policy?(counts, supported_bps, critical_bps),
      failures: results.reject(&:passed).map(&:id)
    )
  end

  # The validated mutation-proof artifact ShadowAcceptance requires, emitted ONLY when the run is
  # genuinely mutation-clean. A non-clean run emits nil, so acceptance fails closed.
  def mutation_proof(counts)
    return nil unless mutation_clean?(counts)

    {
      schema_version: Acceptance::MUTATION_PROOF_SCHEMA,
      source: 'evaluator',
      runs: counts[:runs],
      mutation_observed: false
    }
  end

  # Advisory verdict ONLY. All must hold: schema valid; every critical case passed (100%); overall
  # supported-intent accuracy >= 95%; every supported case's planner ran (repository revalidation);
  # Conversation/Playground parity; and MEASURED mutation-cleanliness. This NEVER activates anything.
  def meets_policy?(counts, supported_bps, critical_bps)
    counts[:schema_valid] &&
      critical_bps >= Corpus::CRITICAL_ACCURACY_BPS &&
      supported_bps >= Corpus::MIN_SUPPORTED_ACCURACY_BPS &&
      counts[:repo_revalidation_ok] &&
      counts[:parity_ok] &&
      mutation_clean?(counts)
  end

  # Integer basis-point rate; an empty denominator scores a perfect 100% (no cases to fail).
  def rate_bps(numerator, denominator)
    return Corpus::BASIS if denominator.zero?

    (numerator * Corpus::BASIS) / denominator
  end

  def invalid_report(reason)
    deep_freeze(schema_version: SCHEMA_VERSION, ok: false, reason: reason,
                mutation_observed: nil, mutation_proof: nil, meets_policy: false)
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end

  # --- injected mutation observer -------------------------------------------------------
  # rubocop:disable Style/OneClassPerFile -- the probe and the read-only repository fakes below are
  # the evaluator's own cohesive injected test doubles; they belong to this seam, not separate files.

  # A simple, injectable observer of the narrow execution. `note_run` is called once per scored case
  # and `note_read` once per injected-repository read. The read-only fakes NEVER call `note_mutation`,
  # so a genuine run reports zero mutations; a test may inject a probe that reports otherwise to prove
  # policy fails closed on a positive delta, and a disconnected probe (runs stays 0) fails closed on
  # missing observer evidence.
  class MutationProbe
    attr_reader :runs, :reads, :mutations

    def initialize
      @runs = 0
      @reads = 0
      @mutations = 0
    end

    def note_run  = (@runs += 1)
    def note_read = (@reads += 1)
    def note_mutation = (@mutations += 1)
  end

  # --- injected read-only repository fakes (no write method exists on any of them) -------

  # Resolves an exact family mention to { code:, name: }, nil (no match), or raises on a
  # :unavailable outage sentinel. Read-only; notifies the probe on every read.
  class FakeFamilyRepository
    def initialize(mapping, probe = nil)
      @mapping = mapping
      @probe = probe
    end

    def resolve_exact(mention)
      @probe&.note_read
      value = @mapping[mention.to_s]
      raise CatalogUnavailable if value == :unavailable

      value
    end
  end

  # Resolves an exact child code (attribute candidates are never passed in 3A) to a resolver result.
  class FakeVariantResolver
    def initialize(mapping, probe = nil)
      @mapping = mapping
      @probe = probe
    end

    def resolve(family_code:, explicit_child_code:, attribute_candidates:) # rubocop:disable Lint/UnusedMethodArgument -- matches the real resolver signature
      @probe&.note_read
      value = @mapping[explicit_child_code.to_s]
      raise CatalogUnavailable if value == :unavailable

      value || { status: :missing, reason: :missing }
    end
  end

  class FakePriceRepository
    def initialize(mapping, probe = nil)
      @mapping = mapping
      @probe = probe
    end

    def price_for(variant_code)
      @probe&.note_read
      value = @mapping[variant_code.to_s]
      raise CatalogUnavailable if value == :unavailable

      value || { status: :unavailable }
    end
  end

  class FakeStockRepository
    def initialize(mapping, probe = nil)
      @mapping = mapping
      @probe = probe
    end

    def status_for(variant_code)
      @probe&.note_read
      value = @mapping[variant_code.to_s]
      raise CatalogUnavailable if value.nil? || value == :unavailable

      value
    end
  end

  # A deterministic price display formatter: always ok, reconstructing a display envelope from the
  # canonical descriptor so the planner's price path completes without a real formatter.
  class FakePriceFormatter
    Result = Struct.new(:ok, :envelope) do
      def ok? = ok
    end

    def format(descriptor:, locale:) # rubocop:disable Lint/UnusedMethodArgument -- matches the real formatter signature
      Result.new(true, {
                   canonical: { variant_code: descriptor[:variant_code], currency: descriptor[:currency],
                                price_list_rate: descriptor[:price_list_rate], uom: descriptor[:uom] },
                   display: { product: descriptor[:variant_code], currency: descriptor[:currency],
                              amount: descriptor[:price_list_rate].to_s, uom: descriptor[:uom] },
                   policy_version: 'synthetic_price_policy_v1'
                 })
    end
  end
  # rubocop:enable Style/OneClassPerFile

  # --- injected surface adapters (Gap 3) ------------------------------------------------

  # A bounded surface adapter: it PROJECTS the canonical turn into a surface-native envelope, then
  # NORMALIZES that envelope back into the canonical backend input. The two surfaces below use
  # genuinely distinct envelope shapes and normalization code, so requiring their folded fingerprints
  # to match proves surface-invariance rather than tautologically re-tagging identical data.
  SurfaceContext = Struct.new(:name, :project, :normalize, keyword_init: true) do
    def adapt(turn)
      normalize.call(project.call(turn))
    end
  end

  # Conversation surface: the turn arrives as an inbound message envelope whose decision plan lives
  # under a :message key and whose capabilities are a list of {key, intents} rows.
  CONVERSATION_SURFACE = SurfaceContext.new(
    name: 'conversation',
    project: lambda do |turn|
      { message: { decision_plan: turn[:plan], selected_scenario: turn[:scenario_key] },
        capability_rows: turn[:capabilities].map { |key, intents| { 'key' => key, 'intents' => intents } } }
    end,
    normalize: lambda do |env|
      { plan: env[:message][:decision_plan],
        scenario_key: env[:message][:selected_scenario],
        capabilities: env[:capability_rows].each_with_object({}) { |row, map| map[row['key']] = row['intents'] } }
    end
  ).freeze

  # Playground surface: the same turn arrives as a flat preview request with a pre-shaped capability
  # map — a genuinely different envelope shape and normalization path.
  PLAYGROUND_SURFACE = SurfaceContext.new(
    name: 'playground',
    project: lambda do |turn|
      { preview_request: { plan: turn[:plan] }, scenario_key: turn[:scenario_key], capability_map: turn[:capabilities] }
    end,
    normalize: lambda do |req|
      { plan: req[:preview_request][:plan], scenario_key: req[:scenario_key], capabilities: req[:capability_map] }
    end
  ).freeze

  SURFACES = [CONVERSATION_SURFACE, PLAYGROUND_SURFACE].freeze
end
# rubocop:enable Metrics/ClassLength
