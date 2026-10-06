# Phase 2 checkpoint A → Phase 3 — synchronous, side-effect-free single-target customer attempt.
#
# The historical class name is kept (the live trigger-bound job references this seam by name), but the
# behaviour is generalized: it builds ONE Decision CandidatePlan (a single Model 1 call) and reuses
# that exact object through the existing Backend Authority to produce ONE target answer — an exact
# price, a bounded product listing, or a bounded product_information listing — whichever single
# authorized product intent the plan carried. It exposes only presenter-validated text; every
# ineligible, malformed, rejected, or exceptional outcome folds to a closed fallback Result so the
# caller runs its unchanged legacy path. It never makes a second Model 1 call per turn.
class Marine::Backend::ExactPriceCustomerExecution
  Coordinator = Marine::Backend::AuthorityCoordinator
  ExecutionPolicy = Marine::Backend::ExecutionPolicy
  EVIDENCE_VERSION = 'marine_evidence_v2'.freeze

  # The exact single-intent target matrix: each accepted response goal maps to the EXACT fact-key set
  # its packet must carry. A target packet carries exactly one of these goals and exactly its fact set
  # — price is unchanged (answer_price → [:price]); the two listing answers carry [:product_listing].
  TARGET_FACTS = {
    'answer_price' => %i[price],
    'answer_product_listing' => %i[product_listing],
    'answer_product_information' => %i[product_listing]
  }.freeze

  STATUS_DELIVERABLE = :deliverable
  STATUS_FALLBACK = :fallback

  REASON_ACCEPTED = :accepted
  REASON_RELATIONSHIP_INVALID = :relationship_invalid
  REASON_SCENARIOS_UNAVAILABLE = :scenarios_unavailable
  REASON_AUTHORITY_REJECTED = :authority_rejected
  REASON_INVALID_PACKET = :invalid_packet
  REASON_PRESENTATION_REJECTED = :presentation_rejected
  REASON_INTERNAL_ERROR = :internal_error

  Result = Struct.new(:status, :reason, :text, keyword_init: true) do
    def deliverable? = status == STATUS_DELIVERABLE
  end

  def initialize(account:, assistant:, conversation:, message:, # rubocop:disable Metrics/ParameterLists -- record boundary plus injectable side-effect-free collaborators
                 decision_runner: nil, scenario_adapter: nil, authority_execution: nil,
                 presenter: nil, generator: nil, fact_verifier: nil, context_builder: nil)
    @account = account
    @assistant = assistant
    @conversation = conversation
    @message = message
    @runner = decision_runner
    @scenario_adapter = scenario_adapter
    @authority_execution = authority_execution
    @presenter = presenter
    @generator = generator
    @fact_verifier = fact_verifier
    @context_builder = context_builder
  end

  def call
    return fallback(REASON_RELATIONSHIP_INVALID) unless valid_relationship?

    context = build_context
    scenarios = enabled_scenarios
    return fallback(REASON_SCENARIOS_UNAVAILABLE) if scenarios.nil?

    execute(context, scenarios)
  rescue StandardError
    fallback(REASON_INTERNAL_ERROR)
  end

  private

  def execute(context, scenarios)
    candidate_plan = runner.call(message: context.trigger, scenarios: scenarios, context: context.history)
    authority_result = execute_authority(candidate_plan)
    return fallback(REASON_AUTHORITY_REJECTED) unless accepted_authority_result?(authority_result)

    packet = authority_result.evidence_packet
    return fallback(REASON_INVALID_PACKET) unless target_packet?(packet)

    present(packet, context)
  end

  def present(packet, context)
    presentation = presenter.call(
      packet: packet,
      generator: generator,
      customer_request: context.trigger,
      message_history: context.history,
      fact_verifier: fact_verifier
    )
    return fallback(REASON_PRESENTATION_REJECTED) unless deliverable_presentation?(presentation)

    deliverable(presentation.text)
  end

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

  def build_context
    (@context_builder || Marine::Conversation::ContextBuilder.new(
      conversation: @conversation, trigger_message: @message
    )).build
  end

  # The adapter's bounded MAX_SCENARIOS + 1 fetch is the complete enabled-scenario seam. Overflow or
  # an empty population fails before Model 1; a partial population is never classified.
  def enabled_scenarios
    adapter = @scenario_adapter || Marine::Decision::ScenarioAdapter.new(assistant: @assistant)
    return nil if adapter.overflow?

    scenarios = adapter.scenarios
    scenarios.is_a?(Array) && scenarios.any? ? scenarios : nil
  end

  def runner
    @runner ||= Marine::Decision::Runner.new(
      classification_intents: ExecutionPolicy::CLASSIFICATION_INTENTS
    )
  end

  # An injected authority is a narrow candidate-plan callable for isolated tests. The production
  # default is the existing AuthorityShadowExecution, preserving Backend-owned repository access and
  # passing the exact CandidatePlan object without another Decision Runner call.
  def execute_authority(candidate_plan)
    return @authority_execution.call(candidate_plan: candidate_plan) if @authority_execution

    Marine::Backend::AuthorityShadowExecution.new(
      account: @account, assistant: @assistant, conversation: @conversation,
      message: @message, candidate_plan: candidate_plan
    ).call
  end

  def accepted_authority_result?(result)
    result.is_a?(Coordinator::Result) &&
      result.outcome_type == Coordinator::OUTCOME_EVIDENCE_PACKET &&
      result.reason == Coordinator::REASON_ACCEPTED &&
      ExecutionPolicy.product_authorized?(result.intents) &&
      result.evidence_packet?
  end

  # A deliverable target packet: deeply frozen marine_evidence_v2, carrying EXACTLY ONE accepted
  # target goal AND exactly that goal's authorized fact-key set (per TARGET_FACTS). A multi-goal
  # packet, an unexpected goal, or a mismatched fact set fails closed to the legacy fallback.
  def target_packet?(packet) # rubocop:disable Metrics/CyclomaticComplexity -- a flat sequence of independent fail-closed packet guards
    return false unless packet.is_a?(Hash) && deeply_frozen?(packet) && packet[:evidence_version] == EVIDENCE_VERSION

    goals = packet[:response_goals]
    return false unless goals.is_a?(Array) && goals.length == 1

    expected = TARGET_FACTS[goals.first]
    !expected.nil? && packet[:facts].is_a?(Hash) && packet[:facts].keys == expected
  end

  def deeply_frozen?(value)
    return false unless value.frozen?

    case value
    when Hash then value.all? { |key, child| key.frozen? && deeply_frozen?(child) }
    when Array then value.all? { |child| deeply_frozen?(child) }
    else true
    end
  end

  def presenter
    @presenter ||= Marine::Backend::EvidencePacketPresenter.new
  end

  def generator
    @generator ||= Marine::Backend::EvidenceReplyGenerator.new
  end

  def fact_verifier
    @fact_verifier ||= Marine::Backend::EvidenceFactVerifier.new
  end

  def deliverable_presentation?(result)
    result.respond_to?(:ok?) && result.ok? && result.respond_to?(:text) &&
      result.text.is_a?(String) && !result.text.strip.empty?
  end

  def deliverable(text)
    Result.new(status: STATUS_DELIVERABLE, reason: REASON_ACCEPTED, text: text.dup.freeze).freeze
  end

  def fallback(reason)
    Result.new(status: STATUS_FALLBACK, reason: reason, text: nil).freeze
  end
end
