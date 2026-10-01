# Fase 3A-2 — SHADOW-ONLY, side-effect-free comparison harness for the PRODUCT authority pipeline.
# Given the account/assistant/conversation/message records for one inbound turn, it computes — for
# LATER (privacy-safe) comparison — both:
#
#   * the LEGACY normalized product outcome from Marine::Catalog::IntentExtractor, and
#   * the CANDIDATE normalized product outcome from the Fase 3A-1
#     Marine::Backend::CandidatePlanToProductIntentAdapter fed by the Decision Runner's canonical
#     CandidatePlan,
#
# on the SAME canonical trigger/history and the SAME bounded scenario population, and returns a small
# deep-frozen in-memory result. Both sides are INJECTED SEAMS (tests inject fakes; no real provider
# runs in a spec).
#
# WHY THIS CANNOT AFFECT PRIMARY BEHAVIOR — the live product reply is produced by
# Marine::Agent::Runner inside Marine::Conversation::ResponseBuilderJob (scheduled at
# Wijaya::Marine::Hooks#schedule_marine_response). This harness runs ONLY inside the fire-and-forget
# Marine::ProductAuthority::ShadowJob, reads records strictly read-only, and returns an in-memory
# comparison — it never touches the reply, routing, action, state, handoff, delivery, or persistence.
# It is the ONLY runtime consumer of Marine::Backend, and it never returns a Backend result into any
# response/state/action path (only the ShadowJob reads it, into aggregate metrics).
#
# Strict discipline:
#   * Validates the four records genuinely belong together and the message is a PUBLIC INCOMING
#     turn; any mismatch returns nil (fail closed, no work).
#   * Fails closed (returns nil, before any extractor/runner/adapter work) when the assistant exposes
#     more than the scenario ceiling, so it never compares a truncated scenario population (bounded
#     input overflow detected before comparing).
#   * Runs the legacy IntentExtractor STATELESS (state: nil) so it reads/mutates NO product-flow
#     state. Beyond the Decision provider that produces the CandidatePlan (and the legacy classifier
#     for the same turn), it performs NO catalog-DB read (adapter-only, never the repository-touching
#     backend execution planner), NO ERP/network call, and mutates NO state.
#   * The returned result carries ONLY closed-enum normalized outcomes — never the caller's records,
#     the raw trigger/history, a candidate slot value, or any id.
class Marine::ProductAuthority::ShadowExecution
  Outcome = Marine::ProductAuthority::ProductOutcome
  Schema = Marine::Decision::Schema

  def initialize(account:, assistant:, conversation:, message:, # rubocop:disable Metrics/ParameterLists -- injected read-only seams (all optional)
                 intent_extractor: nil, decision_runner: nil, adapter: nil,
                 scenario_selector: nil, scenario_adapter: nil, context_builder: nil)
    @account = account
    @assistant = assistant
    @conversation = conversation
    @message = message
    @intent_extractor = intent_extractor
    @decision_runner = decision_runner
    @adapter = adapter
    @scenario_selector = scenario_selector
    @scenario_adapter = scenario_adapter
    @context_builder = context_builder
  end

  # A deep-frozen { legacy:, candidate:, comparable: } result, or nil when the records do not belong
  # together / the message is not a public incoming turn / the scenario population overflows.
  def call
    return nil unless valid_relationship?

    adapter_seam = scenario_adapter
    return nil if adapter_seam.overflow?

    context = build_context
    scenarios = adapter_seam.scenarios

    legacy = Outcome.project(legacy_intent(context))
    candidate = candidate_result(context, scenarios)

    deep_freeze(legacy: legacy, candidate: candidate[:outcome], comparable: candidate[:comparable])
  end

  private

  # Every record must belong to the same account, the message must be this conversation's public
  # incoming turn, and the conversation's inbox must be linked to exactly this Marine assistant.
  def valid_relationship?
    records_present? && same_account? && public_incoming_message? && linked_assistant?
  end

  def records_present?
    [@account, @assistant, @conversation, @message].none?(&:nil?)
  end

  def same_account?
    @message.conversation_id == @conversation.id &&
      @conversation.account_id == @account.id &&
      @assistant.account_id == @account.id
  end

  def public_incoming_message?
    @message.incoming? && !@message.private?
  end

  def linked_assistant?
    inbox = @conversation.inbox
    inbox.present? && inbox.respond_to?(:marine_assistant) && inbox.marine_assistant&.id == @assistant.id
  end

  # The legacy normalized product-intent hash on the SAME canonical trigger/history. STATELESS
  # (state: nil): the shadow reads/mutates no product-flow state.
  def legacy_intent(context)
    intent_extractor.extract(text: context.trigger, context: context.history, state: nil)
  end

  # The candidate side: the Decision Runner's canonical CandidatePlan folded through the Fase 3A-1
  # adapter under the SAME legacy-selected scenario and the SAME per-scenario capability map the
  # Decision Runner was given. `comparable` is true only when the Decision provider genuinely
  # normalized a plan (not a timeout/provider/malformed fallback), so a fallback is never scored as
  # a real product decision.
  def candidate_result(context, scenarios)
    plan = decision_runner.call(message: context.trigger, scenarios: scenarios, context: context.history)
    # A non-normalized plan is a provider/timeout/malformed FALLBACK, not a genuine decision: record a
    # blocked, non-comparable candidate and never run the adapter over a fallback.
    return { outcome: Outcome.blocked, comparable: false } unless plan.is_a?(Hash) && plan[:reason] == Schema::REASON_NORMALIZED

    result = adapter.call(plan: plan, scenario_key: selected_scenario_key(context.trigger),
                          scenario_capabilities: capability_map(scenarios))
    outcome = result.ok? ? Outcome.project(result.product_intent) : Outcome.blocked
    { outcome: outcome, comparable: true }
  end

  # The backend-SELECTED scenario as the SAME `scenario_<id>` stable key the adapter compares the
  # plan's nominated scenario against; nil when the legacy selector matches nothing.
  def selected_scenario_key(trigger)
    selected = scenario_selector.select(trigger)
    selected && "scenario_#{selected.id}"
  end

  # The per-scenario capability map { 'scenario_<id>' => [intents] } derived from the SAME scenario
  # seam the Decision Runner consumed — never a fresh config read, so the two paths share one
  # capability population.
  def capability_map(scenarios)
    scenarios.each_with_object({}) { |scenario, map| map[scenario['key']] = Array(scenario['capabilities']) }
  end

  def build_context
    return @context_builder.call if @context_builder.respond_to?(:call)

    Marine::Conversation::ContextBuilder.new(conversation: @conversation, trigger_message: @message).build
  end

  def intent_extractor
    @intent_extractor ||= Marine::Catalog::IntentExtractor.new(account: @account)
  end

  def decision_runner
    @decision_runner ||= Marine::Decision::Runner.new
  end

  def adapter
    @adapter ||= Marine::Backend::CandidatePlanToProductIntentAdapter.new
  end

  def scenario_selector
    @scenario_selector ||= Marine::Agent::ScenarioSelector.new(assistant: @assistant)
  end

  def scenario_adapter
    @scenario_adapter ||= Marine::Decision::ScenarioAdapter.new(assistant: @assistant)
  end

  # The outcomes are already deep-frozen by ProductOutcome; freeze only the wrapper.
  def deep_freeze(result)
    result.freeze
  end
end
