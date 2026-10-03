# Langkah 3 (Evidence Packet -> Model 2 SHADOW) — the DEFAULT-OFF, read-only, NON-DELIVERING
# execution that turns an ALREADY-ACCEPTED exact-price Evidence Packet into generated Response
# Generator (Model 2) wording purely for shadow observation. It is reached ONLY from
# Marine::Decision::ShadowJob, immediately AFTER the Phase 2A AuthorityShadowExecution, REUSING that
# hook's deep-frozen AuthorityCoordinator::Result — it never recomputes Model 1/JEV and makes no
# second Decision Maker call.
#
# Strict discipline:
#   * Validates the four records genuinely belong together and the message is a PUBLIC INCOMING turn
#     (same contract as AuthorityShadowExecution); a mismatch returns a bounded skipped Result with
#     ZERO provider calls.
#   * Accepts ONLY a genuine AuthorityCoordinator::Result whose outcome is an ACCEPTED exact-price
#     evidence_packet (outcome_type :evidence_packet + reason :accepted + intents EXACTLY
#     AuthorityCoordinator::PRICE_ONLY + a present, frozen, marine_evidence_v1 packet that is itself
#     exactly price-only — response goals [answer_price] and a single :price fact). family_price_range
#     / clarify / handoff / stop / legacy_preserved / non-price / multi-intent / stock-bearing /
#     malformed results skip with ZERO provider calls.
#   * ONLY then rebuilds the bounded ContextBuilder trigger/history and runs the EXISTING
#     EvidencePacketPresenter with the injected Model 2 generator + semantic verifier — the presenter
#     owns generation, the deterministic fact/persona gates, and the separate semantic verification,
#     all fail-closed.
#
# It returns ONLY a deep-frozen, closed status/reason Result and NEVER the generated text. It mutates
# NO state: no create/update/save, no message, no reply/routing/handoff, no product-flow state, no
# cache/metric/log/publish/notify.
class Marine::Backend::Model2ShadowExecution
  Coordinator = Marine::Backend::AuthorityCoordinator
  EVIDENCE_VERSION = 'marine_evidence_v1'.freeze
  # The Step-3 price-only slice generates ONLY an exact price answer: the accepted packet's response
  # goals must be EXACTLY [answer_price] and its facts EXACTLY the single :price fact.
  PRICE_ONLY_GOALS = %w[answer_price].freeze
  PRICE_ONLY_FACTS = %i[price].freeze

  STATUS_ACCEPTED = :accepted
  STATUS_REJECTED = :rejected
  STATUS_SKIPPED = :skipped

  # Accepted: the presenter produced deliverable (but NON-DELIVERED, discarded) wording.
  REASON_DELIVERABLE_WORDING = :deliverable_wording
  # Skipped (zero providers): the turn/outcome was never eligible for Model 2.
  REASON_RELATIONSHIP_INVALID = :relationship_invalid
  REASON_NOT_EXACT_PRICE = :not_exact_price
  REASON_INVALID_PACKET = :invalid_packet
  # Rejected: Model 2 ran but a gate/verifier/internal failure fell closed.
  REASON_INTERNAL_ERROR = :internal_error

  # The EvidencePacketPresenter closed rejection reasons, mapped to this execution's own closed set.
  PRESENTER_REASON = {
    not_generatable: :not_generatable,
    generation_failed: :generation_failed,
    fact_rejected: :fact_rejected,
    persona_rejected: :persona_rejected,
    fact_unverified: :fact_unverified,
    invalid_packet: REASON_INVALID_PACKET
  }.freeze

  # Closed, deep-frozen (symbol fields are already immutable) status/reason result. It NEVER carries
  # generated text, packet facts, ids, or raw provider output.
  Result = Struct.new(:status, :reason, keyword_init: true) do
    def accepted? = status == STATUS_ACCEPTED
  end

  def initialize(account:, assistant:, conversation:, message:, authority_result:, # rubocop:disable Metrics/ParameterLists -- records + reused result + injected read-only collaborators
                 presenter: nil, generator: nil, fact_verifier: nil, context_builder: nil)
    @account = account
    @assistant = assistant
    @conversation = conversation
    @message = message
    @authority_result = authority_result
    @presenter = presenter || Marine::Backend::EvidencePacketPresenter.new
    # The default generator/verifier are built WITHOUT an account so a provider exception inside the
    # shared LLM base service can NEVER construct a ChatwootExceptionTracker (its exception capture is
    # a no-op when account is nil) — no Rails.logger.error, no Sentry publish, no uncontrolled provider
    # text leaked. They still receive the global Response Generator (MARINE_OPEN_AI_*) config; only
    # exception tracking is disabled, honoring Step 3's no-log/no-track/no-publish contract.
    @generator = generator || Marine::Backend::EvidenceReplyGenerator.new
    @fact_verifier = fact_verifier || Marine::Backend::EvidenceFactVerifier.new
    @context_builder = context_builder
  end

  # The bounded, deep-frozen closed Result. Every gate BEFORE the presenter guarantees ZERO Model 2
  # provider calls for a relationship/outcome/packet that is not an accepted exact-price packet.
  def call
    return skipped(REASON_RELATIONSHIP_INVALID) unless valid_relationship?
    return skipped(REASON_NOT_EXACT_PRICE) unless accepted_exact_price?

    packet = @authority_result.evidence_packet
    return skipped(REASON_INVALID_PACKET) unless valid_packet?(packet)
    return skipped(REASON_NOT_EXACT_PRICE) unless exact_price_packet?(packet)

    context = build_context
    result = @presenter.call(
      packet: packet,
      generator: @generator,
      customer_request: context.trigger,
      message_history: context.history,
      fact_verifier: @fact_verifier
    )
    map_result(result)
  rescue StandardError
    rejected(REASON_INTERNAL_ERROR)
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

  # ONLY a genuine AuthorityCoordinator::Result carrying an ACCEPTED exact-price evidence packet may
  # reach Model 2. Any other outcome type / reason / a nil packet fails closed to skipped.
  def accepted_exact_price?
    result = @authority_result
    result.is_a?(Coordinator::Result) &&
      result.outcome_type == Coordinator::OUTCOME_EVIDENCE_PACKET &&
      result.reason == Coordinator::REASON_ACCEPTED &&
      result.intents == Coordinator::PRICE_ONLY &&
      result.evidence_packet?
  end

  # Defense in depth before the presenter: the packet must be a frozen marine_evidence_v1 Hash (the
  # coordinator's builder already deep-freezes it). A malformed/non-frozen/wrong-version packet skips
  # with zero providers.
  def valid_packet?(packet)
    packet.is_a?(Hash) && packet.frozen? && packet[:evidence_version] == EVIDENCE_VERSION
  end

  # Defense in depth before the presenter: even a genuine accepted price Result must carry a packet
  # that is EXACTLY generatable as a price-only answer for this Step-3 slice — response goals EXACTLY
  # [answer_price] and a single :price fact. A forged/malformed multi-intent or stock-bearing packet
  # (an answer_stock goal or a stock fact) is never generatable here and skips with zero provider
  # calls — the Coordinator never produces one, so genuine Phase 2A price packets stay accepted.
  def exact_price_packet?(packet)
    packet[:response_goals] == PRICE_ONLY_GOALS &&
      packet[:facts].is_a?(Hash) && packet[:facts].keys == PRICE_ONLY_FACTS
  end

  def build_context
    (@context_builder || Marine::Conversation::ContextBuilder.new(conversation: @conversation, trigger_message: @message)).build
  end

  # Map the presenter outcome to a closed status/reason — ALWAYS discarding the generated text.
  def map_result(result)
    return accepted(REASON_DELIVERABLE_WORDING) if result.respond_to?(:ok?) && result.ok?

    reason = result.respond_to?(:reason) ? result.reason : nil
    rejected(PRESENTER_REASON.fetch(reason, REASON_INTERNAL_ERROR))
  end

  def accepted(reason) = Result.new(status: STATUS_ACCEPTED, reason: reason).freeze
  def rejected(reason) = Result.new(status: STATUS_REJECTED, reason: reason).freeze
  def skipped(reason) = Result.new(status: STATUS_SKIPPED, reason: reason).freeze
end
