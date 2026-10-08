# Phase 2 checkpoint A → Phase 3 — synchronous, side-effect-free single-target customer attempt.
#
# The historical class name is kept (the live trigger-bound job references this seam by name), but the
# behaviour is generalized: it builds ONE Decision CandidatePlan (a single Model 1 call) and reuses
# that exact object through the existing Backend Authority to produce ONE target answer — an exact
# price, a bounded product listing, or a bounded product_information listing — whichever single
# authorized product intent the plan carried. It exposes only presenter-validated text; every
# ineligible, malformed, rejected, or exceptional outcome folds to a closed fallback Result so the
# caller runs its unchanged legacy path. It never makes a second Model 1 call per turn.
class Marine::Backend::ExactPriceCustomerExecution # rubocop:disable Metrics/ClassLength -- a flat composition root plus its fail-closed packet/version guards
  Coordinator = Marine::Backend::AuthorityCoordinator
  ExecutionPolicy = Marine::Backend::ExecutionPolicy
  EVIDENCE_VERSION = 'marine_evidence_v2'.freeze
  # Checkpoint A — the staged v3 version carrying a presentation_policy, accepted ONLY for the single
  # answer_price_range target. Every other target REMAINS v2; a crossed version fails closed.
  EVIDENCE_VERSION_V3 = 'marine_evidence_v3'.freeze
  RANGE_GOAL = 'answer_price_range'.freeze

  # The closed presentation-policy contract the delivery seam revalidates on a v3 target packet (mirrors
  # PresentationPolicyProjector / EvidencePacketBuilder) — a defense-in-depth structural gate.
  PRESENTATION_POLICY_KEYS = %i[tone verbosity range_followup_mode].freeze
  PRESENTATION_TONES = %w[professional casual formal].freeze
  PRESENTATION_VERBOSITIES = %w[concise detailed].freeze
  PRESENTATION_RANGE_FOLLOWUPS = %w[ask_variant_code standalone].freeze

  # The exact single-intent target matrix: each accepted response goal maps to the EXACT fact-key set
  # its packet must carry. A target packet carries exactly one of these goals and exactly its fact set
  # — price is unchanged (answer_price → [:price]); the two listing answers carry [:product_listing];
  # the Phase-5 answers carry exactly [:price_range] / [:stock].
  TARGET_FACTS = {
    'answer_price' => %i[price],
    'answer_price_range' => %i[price_range],
    'answer_stock' => %i[stock],
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
                 presenter: nil, generator: nil, fact_verifier: nil, context_builder: nil, policy_projector: nil)
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
    @policy_projector = policy_projector
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
    authority_result = execute_authority(candidate_plan, presentation_policy)
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
  def execute_authority(candidate_plan, policy)
    return @authority_execution.call(candidate_plan: candidate_plan, presentation_policy: policy) if @authority_execution

    Marine::Backend::AuthorityShadowExecution.new(
      account: @account, assistant: @assistant, conversation: @conversation,
      message: @message, candidate_plan: candidate_plan, presentation_policy: policy
    ).call
  end

  # The SINGLE per-turn presentation-policy projection (memoized so the projector is called exactly once
  # and the assistant config is read once). It is threaded into the authority execution and reaches the
  # builder on the price_range answer ONLY; every other target ignores it.
  def presentation_policy
    @presentation_policy ||= policy_projector.call
  end

  def policy_projector
    @policy_projector ||= Marine::Backend::PresentationPolicyProjector.new(assistant: @assistant)
  end

  def accepted_authority_result?(result)
    result.is_a?(Coordinator::Result) &&
      result.outcome_type == Coordinator::OUTCOME_EVIDENCE_PACKET &&
      result.reason == Coordinator::REASON_ACCEPTED &&
      ExecutionPolicy.product_authorized?(result.intents) &&
      result.evidence_packet?
  end

  # A deliverable target packet: deeply frozen, carrying EXACTLY ONE accepted target goal AND exactly
  # that goal's authorized fact-key set (per TARGET_FACTS). The version is goal-discriminated:
  # answer_price_range REQUIRES marine_evidence_v3 plus a valid closed presentation_policy; every other
  # target REMAINS marine_evidence_v2 and must NOT carry a presentation_policy. A crossed version
  # (a v2 range packet, or a v3 non-range packet), a multi-goal packet, an unexpected goal, or a
  # mismatched fact set fails closed to the legacy fallback.
  def target_packet?(packet) # rubocop:disable Metrics/CyclomaticComplexity -- a flat sequence of independent fail-closed packet guards
    return false unless packet.is_a?(Hash) && deeply_frozen?(packet)

    goals = packet[:response_goals]
    return false unless goals.is_a?(Array) && goals.length == 1

    expected = TARGET_FACTS[goals.first]
    return false if expected.nil? || !packet[:facts].is_a?(Hash) || packet[:facts].keys != expected

    version_matches?(packet, goals.first)
  end

  def version_matches?(packet, goal)
    if goal == RANGE_GOAL
      packet[:evidence_version] == EVIDENCE_VERSION_V3 && valid_presentation_policy?(packet[:presentation_policy])
    else
      packet[:evidence_version] == EVIDENCE_VERSION && !packet.key?(:presentation_policy)
    end
  end

  def valid_presentation_policy?(policy)
    policy.is_a?(Hash) &&
      policy.keys.sort == PRESENTATION_POLICY_KEYS.sort &&
      PRESENTATION_TONES.include?(policy[:tone]) &&
      PRESENTATION_VERBOSITIES.include?(policy[:verbosity]) &&
      PRESENTATION_RANGE_FOLLOWUPS.include?(policy[:range_followup_mode])
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
