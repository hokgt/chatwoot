# frozen_string_literal: true

# Fase 3A-2 — CONTROLLED, DETERMINISTIC, ADVISORY acceptance RUNNER over an EXPLICITLY-GIVEN set of
# synthetic acceptance cases. It folds every given case EXACTLY ONCE through the canonical
# Marine::ProductAuthority::AcceptancePipelineCoordinator — the real Fase 3A-1 backend pipeline
# (adapter -> planner -> evidence packet builder) — reusing the Evaluator's deterministic injection
# pattern wholesale (the same injected read-only repository fakes, the same shared price formatter, the
# same FIXED_CLOCK, and the same injectable MutationProbe), so each run is DB-free and observed. It
# produces EXACTLY ONE deep-frozen, closed-schema Marine::ProductAuthority::AcceptanceCaseResult per
# executed case (input order preserved) and derives a bounded aggregate report from ONLY those
# CaseResults. It NEVER re-runs the pipeline for aggregation, never adds a second pass/fail classifier
# (pass/fail is the coordinator's own normalized-outcome verdict), and never builds a second per-case
# schema.
#
# It is NOT wired into any live runtime path. It is invoked ONLY by a spec or an operator review. It
# NEVER generates a reply, calls a presenter / LLM / provider, mutates a Message/Conversation, hands
# off, assigns, delivers, reads settings/Redis, touches ShadowMetricsStore, or activates anything.
# Candidate authority (CandidateGate) is untouched and stays phase-locked. Evidence is kept IN-MEMORY
# only (live frozen CaseResult objects in the report's case_evidence); durable retention / persistence
# of acceptance artifacts is an explicit, out-of-scope dependency (no DB table, no Redis, no files).
#
# QUANTITY_INQUIRY — canonical source precedence. The exact-quantity short-circuit is driven by the
# coordinator's `quantity_inquiry` boolean, whose CANONICAL source is the legacy extraction contract
# Marine::Catalog::IntentExtractor#extract (its structured, provider-driven `quantity_inquiry` boolean;
# never raw-text parsing). Corpus cases are plan-based and carry no extractable customer text, so the
# runner resolves the boolean through an INJECTABLE extraction seam that yields that canonical contract
# hash. Precedence: an injected canonical extraction result (a Hash with a boolean :quantity_inquiry)
# TAKES PRECEDENCE; only when no canonical result is available does the runner fall back to the corpus
# `safety.exact_quantity_request` evaluation-only metadata. The runner NEVER parses text and NEVER
# invents a classifier. A FUTURE real-case runner will supply real extraction results (a real seam that
# calls IntentExtractor#extract over the case's real turn); the corpus safety fallback exists ONLY until
# that real acceptance dataset lands. No field is added to the Candidate Plan.
class Marine::ProductAuthority::AcceptanceRunner
  Corpus = Marine::ProductAuthority::Corpus
  Coordinator = Marine::ProductAuthority::AcceptancePipelineCoordinator
  CaseResult = Marine::ProductAuthority::AcceptanceCaseResult
  Outcome = Marine::ProductAuthority::ProductOutcome

  # Reuse the Evaluator's deterministic acceptance plumbing verbatim: its backend class aliases, its
  # fixed clock, its injectable mutation observer, and its read-only repository / price-formatter test
  # doubles. The runner therefore drives the backend pipeline ONLY transitively through the
  # already-declared advisory coordinator + evaluator, and holds no direct backend reference of its own.
  Fakes = Marine::ProductAuthority::Evaluator
  Planner = Fakes::Planner
  EvidenceBuilder = Fakes::EvidenceBuilder
  FIXED_CLOCK = Fakes::FIXED_CLOCK
  # The acceptance-side adapter over the REAL runtime intent seam (Marine::Catalog::IntentExtractor#
  # extract). It is the DEFAULT canonical quantity-inquiry source; when it yields no canonical signal
  # (degraded/malformed extraction) the runner falls back to the corpus safety metadata exactly as
  # before. ShadowAcceptance is referenced ONLY for its mutation-proof schema constant.
  Seam = Marine::ProductAuthority::IntentExtractorSeam
  Acceptance = Marine::ProductAuthority::ShadowAcceptance

  SCHEMA_VERSION = 'marine_product_authority_acceptance_run_v1'

  # Deterministic, bounded correlation id + kind for the OPT-IN retention of a full runner run (the
  # aggregate carries no run identifier, so the caller-supplied id IS the correlation key). A re-save
  # overwrites the same run hash deterministically.
  RETENTION_RUN_ID = 'acceptance_runner_run'
  RETENTION_KIND = 'runner'

  # The single controlled acceptance surface (the existing evaluator convention). Conversation /
  # Playground parity is out of scope, so every case is folded on the `evaluator` surface.
  ACCEPTANCE_SURFACE = 'evaluator'

  # The bounded fallback outcome for the defensive internal-error CaseResult (status unknown, empty
  # closed lists) — used only when the per-case rescue fires, never on a well-formed executable case.
  UNKNOWN_OUTCOME = { status: Outcome::STATUS_UNKNOWN, intents: [], slot_ops: [], response_goals: [] }.freeze

  def self.run(cases = Corpus.cases, extractor: Seam.new, mutation_probe: nil, retention: nil)
    new.run(cases, extractor: extractor, mutation_probe: mutation_probe, retention: retention)
  end

  # A deep-frozen advisory report over the given explicit case set. Never raises. `extractor` is the
  # injectable canonical quantity-inquiry seam (DEFAULT: the real IntentExtractor seam); `mutation_probe`
  # is the injectable observer; `retention` is an OPTIONAL bounded evidence store (anything responding
  # to #save) that retains this run's evidence post-run (default nil -> nothing stored, behavior
  # identical). A degraded seam result falls back to the corpus safety metadata exactly as before.
  def run(cases = Corpus.cases, extractor: Seam.new, mutation_probe: nil, retention: nil)
    return invalid_report('invalid_cases') unless cases.is_a?(Array)

    probe = mutation_probe || Fakes::MutationProbe.new
    evidence = []
    not_executed = 0
    # One canonical coordinator fold per EXECUTABLE case, input order preserved. A case that cannot be
    # folded at all (structurally invalid pre-run) is skipped as not_executed WITHOUT a CaseResult, so
    # a single bad entry never removes the others' results.
    cases.each do |kase|
      if executable_case?(kase)
        evidence << run_case(kase, extractor, probe)
      else
        not_executed += 1
      end
    end
    result = report(evidence, not_executed, cases.length)
    retain(retention, result, evidence, probe)
    result
  rescue StandardError
    invalid_report('run_error')
  end

  private

  # The structural minimum a case needs to be folded through the coordinator at all. A non-Hash entry,
  # a missing/invalid id, or a non-Hash plan/label/repositories cannot be executed and is
  # counted as not_executed (bounded pre-run rejection). Deeper schema faults (a malformed plan, a
  # malformed expected outcome) are NOT rejected here — the coordinator folds them to a bounded
  # malformed/internal result, so they still produce exactly one CaseResult.
  def executable_case?(kase)
    kase.is_a?(Hash) && CaseResult.valid_case_id?(kase[:id]) &&
      kase[:plan].is_a?(Hash) && kase[:label].is_a?(Hash) &&
      kase[:repositories].is_a?(Hash) &&
      kase[:scenario_key].is_a?(String)
  end

  # Fold ONE executable case through the coordinator exactly once. Any unexpected exception (e.g. an
  # exploding injected extraction seam) is captured as a bounded internal_error CaseResult — never an
  # exception message/class/backtrace — so other cases keep their results.
  def run_case(kase, extractor, probe)
    probe.note_run
    quantity_inquiry = resolve_quantity_inquiry(kase, extractor)
    run_coordinator(kase, quantity_inquiry, probe)
  rescue StandardError
    internal_error_case_result(kase)
  end

  # Canonical source precedence (see the class comment): an injected canonical extraction result wins;
  # otherwise fall back to the corpus `safety.exact_quantity_request` evaluation metadata.
  def resolve_quantity_inquiry(kase, extractor)
    canonical = canonical_quantity_inquiry(kase, extractor)
    return canonical unless canonical.nil?

    safety_fallback(kase)
  end

  # The CANONICAL legacy extraction boolean, via the injected seam, or nil when no canonical result is
  # available. The seam is expected to yield the Marine::Catalog::IntentExtractor#extract contract hash
  # (a Hash carrying a boolean :quantity_inquiry) — the same shape ShadowObservation consumes as
  # legacy[:quantity_inquiry]. A non-Hash / non-boolean / absent value contributes no canonical signal.
  def canonical_quantity_inquiry(kase, extractor)
    return nil if extractor.nil?

    result = extractor.call(kase)
    return nil unless result.is_a?(Hash)

    value = result[:quantity_inquiry]
    [true, false].include?(value) ? value : nil
  end

  # Evaluation-only fallback: the corpus `safety.exact_quantity_request` bounded boolean. Never parsed
  # from text; strictly the declared safety-harness metadata.
  def safety_fallback(kase)
    safety = kase[:safety]
    safety.is_a?(Hash) && safety[:exact_quantity_request] == true
  end

  # Fold ONE case through the canonical AcceptancePipelineCoordinator with the SAME DB-free injection
  # pattern the Evaluator uses: fake read-only repositories + the shared mutation probe, and ONE shared
  # deterministic price formatter + the FIXED_CLOCK across planner and evidence builder (so a
  # reconstructed price fact's display + checked_at agree between the two stages). This is the ONLY
  # business execution per case; the aggregate is derived from the resulting CaseResult.
  def run_coordinator(kase, quantity_inquiry, probe)
    formatter = Fakes::FakePriceFormatter.new
    Coordinator.new(
      planner: Planner.new(**planner_repositories(kase, probe, formatter)),
      evidence_builder: EvidenceBuilder.new(clock: FIXED_CLOCK, price_formatter: formatter)
    ).run(
      candidate_plan: kase[:plan],
      scenario_key: kase[:scenario_key],
      quantity_inquiry: quantity_inquiry,
      case_id: kase[:id],
      surface: ACCEPTANCE_SURFACE,
      expected_outcome: expected_outcome(kase[:label])
    )
  end

  def planner_repositories(kase, probe, formatter)
    repos = kase[:repositories]
    {
      family_repository: Fakes::FakeFamilyRepository.new(repos[:family] || {}, probe),
      variant_resolver: Fakes::FakeVariantResolver.new(repos[:variant] || {}, probe),
      price_repository: Fakes::FakePriceRepository.new(repos[:price] || {}, probe),
      stock_repository: Fakes::FakeStockRepository.new(repos[:stock] || {}, probe),
      listing_repository: Fakes::FakeProductListingRepository.new(repos[:listing] || {}, probe),
      price_formatter: formatter,
      clock: FIXED_CLOCK
    }
  end

  # Project the case label into the coordinator's canonical expected-outcome shape. A blocked label's
  # nil response_goals (and any absent list) becomes the canonical empty array the closed outcome
  # requires; the coordinator still fail-closes on a genuinely malformed label.
  def expected_outcome(label)
    { status: label[:status], intents: label[:intents] || [], slot_ops: label[:slot_ops] || [],
      response_goals: label[:response_goals] || [] }
  end

  # A bounded internal-error CaseResult built WITHOUT re-running the pipeline, for the defensive
  # per-case rescue only (all stages skipped). It mirrors the coordinator's own internal_error shape so
  # the per-case evidence collection stays uniform, and leaks no exception text.
  def internal_error_case_result(kase)
    CaseResult.build(
      case_id: CaseResult.valid_case_id?(kase[:id]) ? kase[:id] : 'unknown_case',
      surface: ACCEPTANCE_SURFACE,
      candidate_plan_status: 'skipped', exact_quantity_status: 'skipped', adapter_status: 'skipped',
      planner_status: 'skipped', repository_revalidation_status: 'skipped', evidence_packet_status: 'skipped',
      expected_outcome: UNKNOWN_OUTCOME, actual_outcome: UNKNOWN_OUTCOME,
      reason: CaseResult::REASON_INTERNAL_ERROR, passed: false
    )
  end

  # The aggregate report, DERIVED ONLY from the per-case CaseResults (pass/fail is the coordinator's own
  # verdict, never recomputed here). Deep-freezing leaves each already-frozen CaseResult object intact
  # (never replaced by its to_h), so contract identity is provable. NOTE: case_evidence holds live
  # in-process objects; any serialization boundary MUST project each through #to_h, never dump the raw
  # object.
  def report(evidence, not_executed, total_cases)
    failed = evidence.reject(&:pass?)
    deep_freeze(
      schema_version: SCHEMA_VERSION,
      ok: true,
      total_executed: evidence.length,
      passed: evidence.count(&:pass?),
      failed: failed.length,
      not_executed: not_executed,
      # Every given case produced exactly one CaseResult: none rejected pre-run and the per-case count
      # matches the input length.
      all_evaluated: not_executed.zero? && evidence.length == total_cases,
      failures: failed.map(&:case_id),
      failure_reasons: failed.group_by(&:reason).transform_values(&:length),
      case_evidence: evidence
    )
  end

  def invalid_report(reason)
    deep_freeze(
      schema_version: SCHEMA_VERSION, ok: false, reason: reason,
      total_executed: 0, passed: 0, failed: 0, not_executed: 0,
      all_evaluated: false, failures: [], failure_reasons: {}, case_evidence: []
    )
  end

  # Acceptance-only, post-run, fail-closed retention hook. When a bounded evidence store (anything
  # responding to #save) is injected, project THIS run's aggregate + per-case CaseResults + mutation
  # proof into it; a nil retention (the default) stores nothing and leaves the run identical. A save
  # failure NEVER affects the returned report.
  def retain(retention, result, evidence, probe)
    return unless retention.respond_to?(:save)

    retention.save(
      run_id: RETENTION_RUN_ID,
      kind: RETENTION_KIND,
      aggregate: result,
      mutation_proof: mutation_proof(probe, result[:total_executed]),
      case_results: evidence,
      clock: FIXED_CLOCK
    )
  rescue StandardError
    nil
  end

  # A mutation-proof artifact (the mutation_proof_v1 shape) emitted ONLY when the injected probe
  # observed every executed case and reported zero mutations; otherwise nil, so retention records the
  # explicit absence marker. It is acceptance-run provenance (source 'acceptance_runner') for the audit
  # projection — it is NEVER fed to ShadowAcceptance, which requires the evaluator source.
  def mutation_proof(probe, total_executed)
    return nil unless probe.runs.positive? && probe.runs >= total_executed && !probe.mutations.positive?

    {
      schema_version: Acceptance::MUTATION_PROOF_SCHEMA,
      source: 'acceptance_runner',
      runs: probe.runs,
      mutation_observed: false
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
