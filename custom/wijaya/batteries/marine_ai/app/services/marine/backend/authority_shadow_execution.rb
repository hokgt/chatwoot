# Phase 2A (PRICE-ONLY shadow bridge) — the read-only hook that bridges an ALREADY-COMPUTED JEV
# CandidatePlan into the Backend Authority. It is invoked by Marine::Decision::ShadowJob strictly
# AFTER Marine::Decision::ShadowExecution has produced its deep-frozen { legacy_scenario_key:,
# candidate_plan: } result, REUSING `result[:candidate_plan]` — it never instantiates the Decision
# Runner / ScenarioAdapter and NEVER makes a second JEV/provider call.
#
# Strict discipline (mirrors Decision::ShadowExecution):
#   * Validates the four records genuinely belong together and the message is a PUBLIC INCOMING turn;
#     any mismatch returns nil (fail closed, no work).
#   * Accepts the reused plan ONLY when it is a canonical-normalized plan whose overall AND
#     scenario_candidate confidence are both medium/high (the SAME public
#     CutoverScenarioSelector::ACCEPT_CONFIDENCE contract, without calling the selector's private
#     methods and without running the Runner); otherwise a bounded stop Result.
#   * Re-resolves the nominated scenario key to an ENABLED scenario for THIS assistant via
#     ScenarioResolver (the Decision Maker never carries an enabled/row authority); a miss is a
#     bounded stop Result.
#   * Rebuilds ONLY the bounded ContextBuilder (trigger/history/phase) — never the Runner.
#   * Reads ProductFlowStateStore#current_for_planning ONLY (no start/update/terminate/write).
#   * Loads the assistant's configured language, then calls AuthorityCoordinator and returns ONLY its
#     bounded, deep-frozen Result (§8) — or nil for the relationship/no-work case. Execution
#     authorization is backend-policy-owned (ExecutionPolicy); scenario is provenance only.
#
# It mutates NO state: no create/update/save, no message, no reply/routing/handoff, no product-flow
# state, no cache/metric/log/publish/notify. Its Result never reaches a customer in 2A.
class Marine::Backend::AuthorityShadowExecution
  Schema = Marine::Decision::Schema
  Coordinator = Marine::Backend::AuthorityCoordinator

  # The SAME confidence acceptance the controlled cutover uses — reused so the two can never drift.
  ACCEPT_CONFIDENCE = Marine::Decision::CutoverScenarioSelector::ACCEPT_CONFIDENCE

  def initialize(account:, assistant:, conversation:, message:, candidate_plan:)
    @account = account
    @assistant = assistant
    @conversation = conversation
    @message = message
    @candidate_plan = candidate_plan
  end

  # The bounded, deep-frozen AuthorityCoordinator::Result (§8), or nil when the records do not belong
  # together / the message is not a public incoming turn (no work).
  def call
    return nil unless valid_relationship?
    return Coordinator.stop(reason: Coordinator::REASON_UNSUPPORTED_PLAN) unless acceptable_plan?

    key = candidate_key
    scenario = key && Marine::Decision::ScenarioResolver.resolve(assistant: @assistant, key: key)
    return Coordinator.stop(reason: Coordinator::REASON_SCENARIO_MISMATCH) if scenario.nil?

    context = Marine::Conversation::ContextBuilder.new(conversation: @conversation, trigger_message: @message).build
    Coordinator.new.call(
      candidate_plan: @candidate_plan,
      scenario_key: "scenario_#{scenario.id}",
      trigger: context.trigger, history: context.history, phase: context.phase,
      flow_state: flow_state, configured_language: configured_language
    )
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

  # A canonical-normalized plan whose overall AND scenario_candidate confidence are both medium/high.
  # A timeout/provider/malformed fallback plan (unknown reason) or a low-confidence plan fails closed.
  def acceptable_plan?
    plan = @candidate_plan
    normalized?(plan) && confident?(plan[:confidence]) && confident?(candidate_confidence(plan))
  end

  def normalized?(plan)
    plan.is_a?(Hash) &&
      plan[:schema_version] == Schema::SCHEMA_VERSION &&
      plan[:reason] == Schema::REASON_NORMALIZED
  end

  def confident?(level)
    ACCEPT_CONFIDENCE.include?(level)
  end

  # The nominated scenario key, or nil when absent/blank/non-string (never trusts a non-Hash candidate).
  def candidate_key
    candidate = @candidate_plan.is_a?(Hash) ? @candidate_plan[:scenario_candidate] : nil
    return nil unless candidate.is_a?(Hash)

    key = candidate[:key]
    key.is_a?(String) && !key.strip.empty? ? key : nil
  end

  def candidate_confidence(plan)
    candidate = plan[:scenario_candidate]
    candidate[:confidence] if candidate.is_a?(Hash)
  end

  # Read-only effective planning snapshot; an elapsed ACTIVE flow reads as expired without any write.
  def flow_state
    Marine::Catalog::ProductFlowStateStore.new(conversation: @conversation).current_for_planning
  end

  # The assistant's configured operating language, guarded exactly like the legacy accessor
  # (Marine::Agent::Runner#configured_reply_language); nil when the accessor is not proven.
  def configured_language
    @assistant.config.to_h['language'] if @assistant.respond_to?(:config)
  end
end
