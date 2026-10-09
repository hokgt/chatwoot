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
  PRICE_GOAL = 'answer_price'.freeze
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
    'answer_product_overview' => %i[company_offerings],
    'answer_product_listing' => %i[product_listing],
    'answer_product_information' => %i[product_listing]
  }.freeze

  STATUS_DELIVERABLE = :deliverable
  STATUS_HANDOFF = :handoff
  STATUS_TERMINAL_NO_OUTPUT = :terminal_no_output
  STATUS_FALLBACK = :fallback

  REASON_ACCEPTED = :accepted
  REASON_RELATIONSHIP_INVALID = :relationship_invalid
  REASON_SCENARIOS_UNAVAILABLE = :scenarios_unavailable
  REASON_AUTHORITY_REJECTED = :authority_rejected
  REASON_INVALID_PACKET = :invalid_packet
  REASON_PRESENTATION_REJECTED = :presentation_rejected
  REASON_TRANSITION_REQUIRED = :transition_required
  REASON_HANDOFF_REQUIRED = :handoff_required
  REASON_INTERNAL_ERROR = :internal_error

  # Closed state-transition contracts revalidated at THIS consumer boundary. price_range carries only
  # authoritative family identity; exact price additionally requires the authoritative variant. Unknown
  # keys, mutable graphs, crossed capabilities, forged provenance, and unbounded/blank codes fail closed.
  STATE_TRANSITION_SCHEMA_VERSION = 'state_transition_v1'.freeze
  STATE_TRANSITION_SOURCE = 'marine_catalog'.freeze
  STATE_TRANSITION_KEYS = %i[schema_version operation capability handoff_required authoritative_identity].freeze
  STATE_TRANSITION_IDENTITY_KEYS = {
    'family_context' => %i[family_code source].freeze,
    'price_range' => %i[family_code source].freeze,
    'price' => %i[family_code variant_code source].freeze
  }.freeze
  STATE_TRANSITION_GOALS = {
    RANGE_GOAL => 'price_range',
    PRICE_GOAL => 'price'
  }.freeze
  FAMILY_CONTEXT_GOALS = %w[answer_product_listing answer_product_information].freeze
  CANDIDATE_PLAN_KEYS = %i[
    schema_version scenario_candidate intents slot_operations customer_language confidence reason
  ].freeze
  STATE_TRANSITION_OPERATIONS = %i[start update].freeze
  STATE_TRANSITION_CODE_MAX_BYTES = 120

  Result = Struct.new(:status, :reason, :text, :transition, keyword_init: true) do
    def deliverable? = status == STATUS_DELIVERABLE
    def handoff? = status == STATUS_HANDOFF
    def terminal_no_output? = status == STATUS_TERMINAL_NO_OUTPUT
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
    overview = overview_candidate_plan?(candidate_plan)
    authority_result = execute_authority(candidate_plan, presentation_policy)
    transition = validated_transition(authority_result)
    # A price_range catalog ambiguity surfaces a dedicated handoff Result (the presenter/renderer is
    # never reached, so no visible text is derived from the ambiguity details).
    return handoff(transition) if transition && transition[:handoff_required] == true

    unless accepted_authority_result?(authority_result)
      return terminal_no_output(REASON_AUTHORITY_REJECTED) if overview

      return fallback(REASON_AUTHORITY_REJECTED)
    end

    deliver_target(authority_result.evidence_packet, context, transition, overview: overview)
  rescue StandardError
    return terminal_no_output(REASON_INTERNAL_ERROR) if overview_candidate_plan?(candidate_plan)

    raise
  end

  def deliver_target(packet, context, transition, overview:)
    unless target_packet?(packet)
      return terminal_no_output(REASON_INVALID_PACKET) if overview

      return fallback(REASON_INVALID_PACKET)
    end

    # Exact price and price_range MUST carry their matching valid non-handoff transitions. Without one,
    # fail closed before presentation so a successful target can never outrun its authoritative context.
    goal = packet[:response_goals].first
    required_capability = transition_capability(packet, goal)
    return fallback(REASON_TRANSITION_REQUIRED) if transition_rejected?(transition, packet, required_capability)

    present(packet, context, required_capability ? transition : nil, overview: overview)
  end

  def present(packet, context, transition, overview: false)
    presentation = presenter.call(
      packet: packet,
      generator: generator,
      customer_request: context.trigger,
      message_history: context.history,
      fact_verifier: fact_verifier
    )
    unless deliverable_presentation?(presentation)
      return terminal_no_output(REASON_PRESENTATION_REJECTED) if overview

      return fallback(REASON_PRESENTATION_REJECTED)
    end

    deliverable(presentation.text, transition)
  rescue StandardError
    overview ? terminal_no_output(REASON_PRESENTATION_REJECTED) : fallback(REASON_PRESENTATION_REJECTED)
  end

  def transition_capability(packet, goal)
    return STATE_TRANSITION_GOALS[goal] if STATE_TRANSITION_GOALS.key?(goal)
    return 'family_context' if FAMILY_CONTEXT_GOALS.include?(goal) && packet.dig(:validated_slots, :product, :code)

    nil
  end

  def transition_rejected?(transition, packet, capability)
    capability && (!deliverable_transition?(transition, capability) || !transition_bound_to_packet?(transition, packet, capability))
  end

  def deliverable_transition?(transition, capability)
    !transition.nil? && transition[:handoff_required] == false && transition[:capability] == capability
  end

  # Bind state identity to the accepted Evidence Packet itself. Shape/provenance alone is
  # insufficient: exact price must match every family/variant field; a family-context switch must
  # match the repository-validated product slot and the sole listed product.
  def transition_bound_to_packet?(transition, packet, capability)
    identity = transition[:authoritative_identity]
    if capability == 'price'
      family_codes = [identity[:family_code], packet.dig(:validated_slots, :product, :code)]
      variant_codes = [identity[:variant_code], packet.dig(:validated_slots, :variant, :code),
                       packet.dig(:facts, :price, :canonical, :variant_code)]
      return matching_codes?(family_codes) && matching_codes?(variant_codes)
    end
    return family_context_bound?(identity, packet) if capability == 'family_context'

    true
  end

  def family_context_bound?(identity, packet)
    products = packet.dig(:facts, :product_listing, :products)
    products.is_a?(Array) && products.length == 1 &&
      matching_codes?([identity[:family_code], packet.dig(:validated_slots, :product, :code), products.first[:code]])
  end

  def matching_codes?(codes)
    codes.all? { |code| valid_code?(code) } && codes.uniq.one?
  end

  # Revalidate the AuthorityCoordinator's proposed_state_transition against the closed contract at this
  # consumer boundary: a non-Hash, shallow-frozen, unknown/extra-key, wrong-schema/capability/operation,
  # or malformed-identity envelope is rejected (nil), so only a well-formed transition is ever surfaced.
  def validated_transition(authority_result)
    raw = authority_result.respond_to?(:proposed_state_transition) ? authority_result.proposed_state_transition : nil
    valid_transition?(raw) ? raw : nil
  end

  def valid_transition?(transition)
    return false unless transition.is_a?(Hash) && deeply_frozen?(transition)
    return false unless transition.keys.sort == STATE_TRANSITION_KEYS.sort
    return false unless transition[:schema_version] == STATE_TRANSITION_SCHEMA_VERSION
    return false unless STATE_TRANSITION_IDENTITY_KEYS.key?(transition[:capability])
    return false unless STATE_TRANSITION_OPERATIONS.include?(transition[:operation])

    valid_transition_identity?(transition)
  end

  # authoritative_identity MAY be nil IFF handoff_required is true; when false it MUST be the exact closed
  # { family_code:, source: } pair with a nonblank bounded family_code and the exact marine_catalog source.
  def valid_transition_identity?(transition)
    case transition[:handoff_required]
    when true
      transition[:capability] == 'price_range' && transition[:authoritative_identity].nil?
    when false
      valid_identity?(transition[:authoritative_identity], transition[:capability])
    else false
    end
  end

  def valid_identity?(identity, capability)
    expected_keys = STATE_TRANSITION_IDENTITY_KEYS[capability]
    return false unless identity.is_a?(Hash) && deeply_frozen?(identity)
    return false unless identity.keys.sort == expected_keys.sort
    return false unless valid_code?(identity[:family_code]) && identity[:source] == STATE_TRANSITION_SOURCE

    capability != 'price' || valid_code?(identity[:variant_code])
  end

  def valid_code?(value)
    value.is_a?(String) && !value.strip.empty? && value.bytesize <= STATE_TRANSITION_CODE_MAX_BYTES
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

  def overview_candidate_plan?(candidate_plan)
    candidate_plan.is_a?(Hash) && deeply_frozen?(candidate_plan) &&
      candidate_plan.keys.sort == CANDIDATE_PLAN_KEYS.sort &&
      candidate_plan[:schema_version] == Marine::Decision::Schema::SCHEMA_VERSION &&
      candidate_plan[:intents] == ['product_overview'] &&
      candidate_plan[:reason] == Marine::Decision::Schema::REASON_NORMALIZED
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

  def deliverable(text, transition = nil)
    Result.new(status: STATUS_DELIVERABLE, reason: REASON_ACCEPTED, text: text.dup.freeze, transition: transition).freeze
  end

  # A catalog-ambiguity handoff: carries the validated handoff envelope (so the job routes the existing
  # safe handoff and writes no state) and NO text — the renderer/presenter was never reached.
  def handoff(transition)
    Result.new(status: STATUS_HANDOFF, reason: REASON_HANDOFF_REQUIRED, text: nil, transition: transition).freeze
  end

  def terminal_no_output(reason)
    Result.new(status: STATUS_TERMINAL_NO_OUTPUT, reason: reason, text: nil, transition: nil).freeze
  end

  def fallback(reason)
    Result.new(status: STATUS_FALLBACK, reason: reason, text: nil, transition: nil).freeze
  end
end
