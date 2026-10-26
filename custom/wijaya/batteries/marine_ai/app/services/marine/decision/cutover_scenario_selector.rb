# CONTROLLED scenario-selection wrapper for the Marine agent runner (Phase 2 / Stage 6 — the ONLY
# cutover authority seam). It sits in front of the legacy token-overlap Marine::Agent::ScenarioSelector
# and, ONLY when the fail-closed Marine::Decision::CutoverGate is open for this account+assistant,
# lets the Decision Maker's canonical CandidatePlan choose the scenario — otherwise it defers to the
# legacy selector, byte-for-byte as before.
#
# Scope discipline — this is the ONLY behavior that changes under cutover:
#   * It selects a SCENARIO only. It never touches reply text, routing, product/price/stock/quantity,
#     handoff, or conversation state, and never forwards the plan's candidate intents/slots/values.
#   * Query blank OR gate closed => the legacy selector runs directly; the ScenarioAdapter, the
#     Decision Runner, the metrics snapshot (beyond the gate's own read), and the provider are NEVER
#     touched.
#   * Gate open => it builds the FULL enabled scenario seam via Marine::Decision::ScenarioAdapter. An
#     overflow (truncated population) or an empty/malformed seam falls back to legacy. Otherwise it
#     calls Marine::Decision::Runner EXACTLY once with message = query, the bounded recent role/content
#     context, state = {} (no invented/forwarded product facts), and the adapter scenarios.
#   * The Decision choice is accepted ONLY when the plan is a canonical normalized plan (exact schema,
#     reason == normalized), its overall confidence and its scenario_candidate confidence are both
#     medium/high, a scenario_candidate key is present, AND Marine::Decision::ScenarioResolver
#     re-resolves that key to an ENABLED scenario for the SAME assistant. Anything else — unknown
#     plan, nil key, low confidence, malformed shape, timeout/provider error, resolver miss, or any
#     exception — falls back to the legacy selector.
#
# The legacy selector executes AT MOST once and the Decision Runner AT MOST once. Decision-side
# failures (gate/adapter/Decision Runner/plan/resolver) NEVER escape — they fold to a legacy
# fallback — so the cutover can never turn a decision error into a handoff or a changed reply. A
# legacy selector failure is deliberately NOT swallowed: it propagates to Marine::Agent::Runner#run,
# whose top-level rescue degrades to the historical safe handoff exactly as before Stage 6, when this
# seam called the legacy selector directly. It never changes the reply and returns a small immutable
# Selection carrying the chosen scenario plus closed source/reason enums so the caller can log safe
# routing metadata with no raw query/content/candidate values. An optional
# ActiveSupport::Notifications event carries only ids + source/reason; a notification failure never
# affects the selection.
class Marine::Decision::CutoverScenarioSelector
  Schema = Marine::Decision::Schema

  SOURCE_DECISION = 'decision'.freeze
  SOURCE_LEGACY = 'legacy'.freeze

  # Closed, bounded reason vocabulary — never a raw value. One accepted code for the decision path;
  # the rest explain why the selection fell back to legacy.
  REASON_ACCEPTED = 'decision_accepted'.freeze
  REASON_BLANK_QUERY = 'blank_query'.freeze
  REASON_GATE_CLOSED = 'gate_closed'.freeze
  REASON_SEAM_OVERFLOW = 'scenario_seam_overflow'.freeze
  REASON_SEAM_EMPTY = 'scenario_seam_empty'.freeze
  REASON_PLAN_UNKNOWN = 'plan_not_normalized'.freeze
  REASON_PLAN_LOW_CONFIDENCE = 'plan_low_confidence'.freeze
  REASON_NO_CANDIDATE = 'plan_no_scenario_candidate'.freeze
  REASON_RESOLVER_MISS = 'resolver_miss'.freeze
  REASON_ERROR = 'error'.freeze

  # Only a medium/high plan (and scenario_candidate) confidence is trusted to cut over.
  ACCEPT_CONFIDENCE = %w[medium high].freeze
  # The bounded prior-turn ceiling the Decision InputContract itself accepts.
  MAX_CONTEXT = Marine::Decision::InputContract::MAX_CONTEXT_ENTRIES
  CONTEXT_ROLES = %w[user assistant].freeze

  NOTIFICATION = 'marine.decision.cutover.scenario_selection'.freeze

  # A small, immutable selection result: the chosen scenario (or nil) plus the closed source/reason
  # enums. `scenario_id` is a safe id-only accessor for logging/notifications.
  Selection = Struct.new(:scenario, :source, :reason) do
    def decision? = source == SOURCE_DECISION
    def legacy? = source == SOURCE_LEGACY
    def scenario_id = scenario&.id
  end

  def initialize(assistant:, account_id:, gate: nil, decision_runner: nil, legacy_selector: nil, # rubocop:disable Metrics/ParameterLists
                 resolver_class: Marine::Decision::ScenarioResolver, adapter_class: Marine::Decision::ScenarioAdapter)
    @assistant = assistant
    @account_id = account_id
    @gate = gate || Marine::Decision::CutoverGate.new
    @decision_runner = decision_runner
    @legacy_selector = legacy_selector
    @resolver_class = resolver_class
    @adapter_class = adapter_class
  end

  # Returns a frozen Selection. Decision-side failures (gate/adapter/Decision Runner/plan/resolver)
  # never escape — they fall back to the legacy selector. A legacy selector error is NOT swallowed: it
  # propagates so Marine::Agent::Runner#run degrades to its historical safe handoff. The legacy
  # selector runs at most once; the Decision Runner runs at most once.
  def select(query, context: [])
    scenario, reason = attempt(query, context)
    selection =
      if scenario
        Selection.new(scenario, SOURCE_DECISION, REASON_ACCEPTED)
      else
        Selection.new(legacy_scenario(query), SOURCE_LEGACY, reason)
      end.freeze
    notify(selection)
    selection
  end

  private

  # [scenario, nil] on an accepted decision, or [nil, reason] to fall back to legacy. Never raises:
  # any exception folds to a legacy fallback with REASON_ERROR, so the reply is never affected.
  def attempt(query, context)
    return [nil, REASON_BLANK_QUERY] if query.blank?
    return [nil, REASON_GATE_CLOSED] unless gate_open?

    decide(query, context)
  rescue StandardError
    [nil, REASON_ERROR]
  end

  # Build the full enabled scenario seam and run the Decision Runner exactly once. An overflow or
  # an empty seam falls back to legacy without calling the Runner/provider.
  def decide(query, context)
    adapter = @adapter_class.new(assistant: @assistant)
    return [nil, REASON_SEAM_OVERFLOW] if adapter.overflow?

    scenarios = adapter.scenarios
    return [nil, REASON_SEAM_EMPTY] if scenarios.blank?

    plan = decision_runner.call(message: query, scenarios: scenarios, context: bounded_context(context), state: {})
    accept(plan)
  end

  # The full accept contract, short-circuiting to the FIRST failing condition's bounded reason.
  # Returns [scenario, nil] only when every condition holds.
  def accept(plan)
    return [nil, REASON_PLAN_UNKNOWN] unless normalized?(plan)
    return [nil, REASON_PLAN_LOW_CONFIDENCE] unless confident?(plan[:confidence])

    key = candidate_key(plan)
    return [nil, REASON_NO_CANDIDATE] if key.nil?
    return [nil, REASON_PLAN_LOW_CONFIDENCE] unless confident?(candidate_confidence(plan))

    scenario = @resolver_class.new(assistant: @assistant).resolve(key)
    return [nil, REASON_RESOLVER_MISS] if scenario.nil?

    [scenario, nil]
  end

  # A canonical normalized CandidatePlan: exact v1 schema AND the normalized outcome reason. A
  # timeout/provider/malformed fallback plan carries an unknown reason and is rejected here.
  def normalized?(plan)
    plan.is_a?(Hash) &&
      plan[:schema_version] == Schema::SCHEMA_VERSION &&
      plan[:reason] == Schema::REASON_NORMALIZED
  end

  def confident?(level)
    ACCEPT_CONFIDENCE.include?(level)
  end

  # The nominated scenario key, or nil when absent/blank/non-string. Never trusts a non-Hash
  # scenario_candidate.
  def candidate_key(plan)
    candidate = plan[:scenario_candidate]
    return nil unless candidate.is_a?(Hash)

    key = candidate[:key]
    key.is_a?(String) && !key.strip.empty? ? key : nil
  end

  def candidate_confidence(plan)
    candidate = plan[:scenario_candidate]
    candidate[:confidence] if candidate.is_a?(Hash)
  end

  # The legacy token-overlap choice for this query. Executed at most once (only on the fallback
  # branch). A legacy selector error is deliberately NOT rescued here: it propagates to the caller
  # (Marine::Agent::Runner#run), whose top-level rescue degrades to the historical safe handoff —
  # exactly as before Stage 6, when this seam called the legacy selector directly. Only decision-side
  # failures fall back to legacy; they never mask a genuine legacy failure.
  def legacy_scenario(query)
    legacy_selector.select(query)
  end

  def gate_open?
    @gate.open?(account_id: @account_id, assistant_id: assistant_id)
  end

  # A bounded, role/content-only view of the recent turns for the Decision Runner: the last
  # MAX_CONTEXT entries that already carry a valid role and non-blank content. It forwards NO
  # product facts, ids, or candidate values — only prior turn text the InputContract re-bounds.
  def bounded_context(context)
    Array(context).filter_map { |entry| context_entry(entry) }.last(MAX_CONTEXT)
  end

  def context_entry(entry)
    return nil unless entry.is_a?(Hash)

    role = (entry[:role] || entry['role']).to_s
    content = entry[:content] || entry['content']
    return nil unless CONTEXT_ROLES.include?(role) && content.is_a?(String) && content.strip.present?

    { 'role' => role, 'content' => content }
  end

  # Lazily built so the closed path never constructs a Decision Runner (which reads decision-maker
  # settings) and so tests can inject one.
  def decision_runner
    @decision_runner ||= Marine::Decision::Runner.new
  end

  def legacy_selector
    @legacy_selector ||= Marine::Agent::ScenarioSelector.new(assistant: @assistant)
  end

  # Optional, best-effort routing telemetry carrying ONLY ids + the closed source/reason enums —
  # never the raw query, context, or any candidate value. A notification failure never affects the
  # selection.
  def notify(selection)
    ActiveSupport::Notifications.instrument(
      NOTIFICATION,
      account_id: @account_id,
      assistant_id: assistant_id,
      scenario_id: selection.scenario_id,
      source: selection.source,
      reason: selection.reason
    )
  rescue StandardError
    nil
  end

  def assistant_id
    @assistant.id if @assistant.respond_to?(:id)
  end
end
