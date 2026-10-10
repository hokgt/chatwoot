# SHADOW-ONLY, side-effect-free comparison harness for the isolated Marine Decision Runner
# (Phase 2 / Stage 4). Given the account/assistant/conversation/message records for one
# inbound turn, it computes — for LATER (Stage 5) comparison — both the LEGACY scenario
# choice (Marine::Agent::ScenarioSelector) and the Decision Maker's canonical CandidatePlan
# (Marine::Decision::Runner), on the SAME canonical trigger and scenario seam, and returns a
# small deep-frozen in-memory result.
#
# Strict discipline — it NEVER influences the live reply:
#   * Validates the four records genuinely belong together and the message is a PUBLIC
#     INCOMING turn; any mismatch returns nil (fail closed, no work).
#   * Fails closed (returns nil, before the selector/Runner run) when the assistant exposes
#     more than the contract's scenario ceiling of enabled scenarios, so the comparison never
#     runs against a silently-truncated scenario population.
#   * Uses the existing Marine::Conversation::ContextBuilder for the bounded trigger/history
#     and Marine::Agent::ScenarioSelector / Marine::Decision::Runner strictly read-only.
#   * Mutates NO state: no create/update/save, no message, no reply/routing/handoff, no
#     product-flow state, no cache/metric/log/publish/notify.
#   * The returned result carries ONLY the legacy stable scenario key and the canonical
#     CandidatePlan — never the caller's records or the raw customer trigger/history text.
class Marine::Decision::ShadowExecution
  def initialize(account:, assistant:, conversation:, message:, classification_intents:)
    @account = account
    @assistant = assistant
    @conversation = conversation
    @message = message
    @classification_intents = classification_intents
  end

  # A deep-frozen { legacy_scenario_key:, candidate_plan: } result, or nil when the records
  # do not belong together / the message is not a public incoming turn / the injected
  # classification vocabulary is missing or malformed (the Runner is never run on a garbage
  # vocabulary).
  def call
    return nil unless valid_relationship?
    return nil unless valid_classification_intents?

    # Overflow fails closed BEFORE the legacy selector or the Decision Runner runs: when the
    # assistant has more than the contract ceiling of enabled scenarios, the adapter can only
    # offer a truncated head, so the two paths would compare different populations. Bail rather
    # than compare a partial set (no invented scenario, no partial comparison).
    adapter = Marine::Decision::ScenarioAdapter.new(assistant: @assistant)
    return nil if adapter.overflow?

    context = Marine::Conversation::ContextBuilder.new(conversation: @conversation, trigger_message: @message).build
    scenarios = adapter.scenarios

    result = {
      legacy_scenario_key: legacy_scenario_key(context.trigger),
      candidate_plan: candidate_plan(context, scenarios)
    }
    deep_freeze(result)
  end

  private

  # Every record must belong to the same account, the message must be this conversation's
  # public incoming turn, and the conversation's inbox must be linked to exactly this
  # Marine assistant. Anything else fails closed.
  def valid_relationship?
    records_present? && same_account? && public_incoming_message? && linked_assistant?
  end

  def records_present?
    [@account, @assistant, @conversation, @message].none?(&:nil?)
  end

  # The injected classification vocabulary must be a non-empty Array of Strings; anything else
  # fails closed (no comparison) so the Runner never runs on a missing/garbage vocabulary.
  def valid_classification_intents?
    @classification_intents.is_a?(Array) && !@classification_intents.empty? &&
      @classification_intents.all?(String)
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

  # The legacy candidate rendered as the SAME `scenario_<id>` stable key the Decision Runner
  # uses (via the ScenarioAdapter), so the two are directly comparable. nil when the selector
  # matches nothing.
  def legacy_scenario_key(trigger)
    selected = Marine::Agent::ScenarioSelector.new(assistant: @assistant).select(trigger)
    selected && "scenario_#{selected.id}"
  end

  # The canonical, deep-frozen CandidatePlan on the same canonical trigger/history/scenarios, over the
  # injected Phase-1 classification vocabulary. The Runner never raises and never mutates state; no
  # coarse state hint is supplied.
  def candidate_plan(context, scenarios)
    Marine::Decision::Runner.new(classification_intents: @classification_intents)
                            .call(message: context.trigger, scenarios: scenarios, context: context.history)
  end

  # Freeze the small result wrapper and its own string; the CandidatePlan is already
  # deep-frozen by its factory.
  def deep_freeze(result)
    result[:legacy_scenario_key] = result[:legacy_scenario_key].dup.freeze if result[:legacy_scenario_key]
    result.freeze
  end
end
