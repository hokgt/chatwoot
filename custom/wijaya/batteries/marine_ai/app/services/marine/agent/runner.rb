# Marine agent runner — the top-level orchestration layer for automated Marine
# replies. It ties together the already implemented Marine pieces behind a single
# deterministic, always-safe entry point:
#
#   * retrieval/knowledge answer generation, citations and confidence,
#   * multilingual detection/translation metadata,
#   * enabled scenario selection (deterministic keyword matching),
#   * Marine fallback/handoff behavior,
#   * structured production logging/observability.
#
# Custom HTTP tools have been removed to eliminate all direct outbound
# connectivity between Marine AI and ERP. The runner no longer resolves any
# tools; the marine_scenario_tools payload key is retained as an empty array for
# downstream payload compatibility.
#
# Safety contract (holds even when the Marine LLM is blank/unconfigured on dev):
#   * never raises — any unexpected error degrades to a handoff payload;
#   * performs no external calls itself and exposes no tools;
#   * always returns a payload shape compatible with the existing response path
#     (Marine::Charge::ResponseGenerator), enriched with orchestration metadata.
#
# Fully Marine-owned: no Captain runtime classes, hub checks, pricing plans, or
# premium feature flags.
# rubocop:disable Metrics/ClassLength -- a single cohesive top-level orchestration boundary:
# product/playground pre-RAG routing, Gate G FAQ precedence, ephemeral Playground state
# preservation, greeting phasing, and the always-safe fallback belong to one entry point.
class Marine::Agent::Runner
  LOG_PREFIX = '[Marine::Agent::Runner]'.freeze
  RUNNER_ERROR_REASON = 'runner_error'.freeze

  PATH_HANDOFF = 'handoff'.freeze
  PATH_RETRIEVAL = 'retrieval'.freeze
  PATH_SCENARIO_RETRIEVAL = 'scenario_retrieval'.freeze
  PATH_PRODUCT = 'product'.freeze

  # Gate G — fail-closed FAQ/KB precedence over product orchestration. The untrusted LLM
  # intent extractor can wrongly classify a turn as product_related; that error must never
  # preempt an approved answer the deterministic retrieval layer already scores as an EXACT
  # match. EXACT is the highest-confidence tier (ConfidenceScorer::EXACT_MATCH_SCORE) — the
  # same bar the RAG ResponseGenerator itself trusts to answer verbatim from approved content
  # without synthesis — so only a curated, approved, exactly-matching FAQ/KB entry qualifies.
  # Any lower-confidence, token-blended, or fallback retrieval yields to Product Flow, so weak
  # or unmatched retrieval is never turned into a FAQ answer and genuine product requests still
  # use Product Flow. Generic and data-driven: no question/product/language/phrase handling.
  FAQ_PRECEDENCE_MIN_CONFIDENCE = Marine::Charge::ConfidenceScorer::EXACT_MATCH_SCORE

  PLAYGROUND_SOURCE = 'playground'.freeze

  def initialize(assistant:, conversation: nil, source: nil, state_token: nil)
    @assistant = assistant
    @conversation = conversation
    @source = source
    @state_token = state_token
  end

  # A trigger-bound run derives its prior history and separately bounded current trigger from
  # the canonical ContextBuilder (source = the incoming Message), so both the product-intent
  # and RAG paths ground on the SAME prior turns and receive the trigger exactly once. A legacy
  # (source-less) or direct-unit run has no trigger and falls back to the caller-supplied
  # additional_message / message_history unchanged.
  def run(additional_message: nil, message_history: [])
    context = canonical_context
    history = context ? context.history : Array(message_history)
    trigger = context ? context.trigger : additional_message
    query = resolve_query(trigger, history)

    log_event('runner.start', assistant_id: assistant_id, conversation_id: conversation_id,
                              source: source_label, query_present: query.present?,
                              interaction_phase: context&.phase)

    # Product orchestration BEFORE RAG: the trigger-bound conversation path (product_payload) or,
    # for a source-less run with no conversation, the read-only Playground catalog preview. Both
    # return nil to fall through to the unchanged retrieval path.
    orchestrated = product_payload(context, query) || playground_preview(query, history)
    return orchestrated if orchestrated

    scenario = select_scenario(query)
    tool_slugs = resolved_tool_slugs(scenario)

    payload = response_generator.generate(additional_message: trigger, message_history: history,
                                          opening: interaction_opening?(context, history))
    enriched = preserve_playground_state(enrich(payload, scenario, tool_slugs))

    log_result(enriched)
    enriched
  rescue StandardError => e
    handle_error(e)
  end

  private

  attr_reader :assistant, :conversation, :source, :state_token

  # Canonical bounded prior history + separately bounded current trigger + interaction phase
  # for a trigger-bound turn; nil when there is no incoming trigger message (legacy / direct
  # callers), so the caller-supplied history/message is used unchanged.
  def canonical_context
    message = trigger_message
    return nil unless message && conversation

    Marine::Conversation::ContextBuilder.new(conversation: conversation, trigger_message: message).build
  end

  # Canonical interaction phase for the greeting gate. A trigger-bound run uses the
  # ContextBuilder phase directly. A source-less run (the legacy ResponseBuilderJob path or any
  # direct source-less caller) has no trigger boundary, so it derives the SAME rule straight
  # from the Conversation: greeting is opening ONLY until Marine has posted any earlier PUBLIC
  # reply — once any public Marine response exists, every later generation for that Conversation
  # is a follow-up, with no inactivity/status/reopen heuristic re-enabling opening. A nil
  # conversation (playground / direct-unit) has no Conversation to inspect, so the supplied
  # history decides: an opening turn is one with no prior assistant reply yet. Empty history keeps
  # the prior opening default (true), so legacy source-less callers are unaffected.
  def interaction_opening?(context, history)
    return context.opening? if context
    return !earlier_public_marine_reply? if conversation

    source_less_opening?(history)
  end

  # Nil-conversation source-less phase: opening until the caller-supplied history already carries
  # an assistant turn (the multi-turn playground preview), follow-up thereafter. No greeting is
  # re-emitted on every turn of a running preview, matching a real conversation's follow-up gating.
  def source_less_opening?(history)
    Array(history).none? { |item| (item[:role] || item['role']).to_s == 'assistant' }
  end

  # Any public Marine reply already sent in this Conversation. Reuses the canonical
  # ContextBuilder sender_type (no new sender/phrase constant); private Marine notes and human
  # User replies never match, so neither turns a source-less run into a follow-up. Used only on
  # the source-less path, where there is no trigger boundary and existence alone decides.
  def earlier_public_marine_reply?
    conversation.messages
                .exists?(message_type: :outgoing, private: false,
                         sender_type: Marine::Conversation::ContextBuilder::MARINE_SENDER_TYPE)
  end

  # Phase 5 — product orchestration runs BEFORE general RAG. Only active on a trigger-bound
  # run (canonical context present, i.e. the job passed the exact incoming Message as
  # `source:`); a legacy (source-less) run gets no context and skips it entirely, behaving
  # exactly as before. The deterministic Phase 4 orchestrator plans over the SEPARATELY
  # bounded current trigger (context.trigger, capped at 4,000 chars) and the canonical prior
  # history (context.history, trigger excluded — no duplicate current-message concatenation),
  # plus the current (read-only) flow snapshot. A `:not_product` plan returns nil so the caller
  # falls through to the unchanged retrieval path; any other action is returned as a product
  # payload the ResponseBuilderJob finalizes (state apply + deterministic TEXT / handoff).
  # Unexpected errors propagate to the runner's own fail-safe (handoff payload), never a
  # fabricated product answer. Gate G: an EXACT approved FAQ/KB match (#faq_precedence?) short-
  # circuits BEFORE the orchestrator so an erroneous product classification cannot preempt it.
  def product_payload(context, query)
    return nil unless context

    kb = knowledge_result(query)
    return nil if faq_precedence?(kb)

    plan = product_orchestrator.process(text: context.trigger, context: context.history,
                                        flow: product_flow, suppressed: false,
                                        knowledge_available: knowledge_available?(kb))
    return nil if plan[:action] == :not_product

    log_event('answer.product', action: plan[:action])
    { 'action' => 'product', 'orchestration_path' => PATH_PRODUCT, 'product_plan' => plan }
  end

  # One deterministic approved-KB retrieval for this turn's query, shared by Gate G
  # (#faq_precedence?) and the informational KB-availability signal (#knowledge_available?) so a
  # single retrieve serves both. Assistant/account-scoped, approved-only. nil for a blank query.
  def knowledge_result(query)
    return nil if query.blank?

    knowledge_base.retrieve(query, limit: 1)
  end

  # True when an approved FAQ/KB entry EXACTLY matches this turn's query, so the turn must be
  # answered via the unchanged retrieval path instead of product orchestration. Requires a
  # confident (non-fallback) EXACT match. An empty/low-confidence/token-blended/fallback result
  # never grants precedence (fail closed), so product routing is preserved for every genuine
  # product request. See FAQ_PRECEDENCE_MIN_CONFIDENCE.
  def faq_precedence?(result)
    return false if result.nil?
    return false unless result.fallback_reason.blank? && result.confidence >= FAQ_PRECEDENCE_MIN_CONFIDENCE

    log_event('faq.precedence', confidence: result.confidence, source_type: result.source_type)
    true
  end

  # Whether the approved Knowledge Base CONFIDENTLY answers this turn (a non-fallback retrieval
  # match, at any confidence tier — not only the EXACT tier Gate G requires). Injected into the
  # product orchestrator so an INFORMATIONAL product turn (parent_info / variant_info / an
  # unsupported product question) the KB actually answers defers to grounded KB retrieval instead
  # of an attribute-free catalog echo, clarification, or handoff. The orchestrator ignores it for
  # transactional price/stock/catalog and exact-quantity turns, so their deterministic / fail-closed
  # behavior is untouched. Fail closed: nil / fallback result yields false.
  def knowledge_available?(result)
    return false if result.nil?

    result.fallback_reason.blank?
  end

  def knowledge_base
    @knowledge_base ||= Marine::Cell::KnowledgeBaseService.new(assistant: assistant)
  end

  def trigger_message
    source if source.is_a?(::Message) && source.incoming?
  end

  def product_orchestrator
    @product_orchestrator ||= Marine::Catalog::ProductQueryOrchestrator.new(
      intent_extractor: Marine::Catalog::IntentExtractor.new(account: product_account)
    )
  end

  # Read-only EFFECTIVE planning snapshot for the orchestrator; never mutated here — the
  # job applies any state operation at finalization. An elapsed active flow is presented as
  # expired (status 'expired') WITHOUT persisting the transition, so reasoning never reuses an
  # expired flow's validated family/variant/catalog markers or clarification count.
  def product_flow
    Marine::Catalog::ProductFlowStateStore.new(conversation: conversation).current_for_planning
  end

  def product_account
    conversation&.account || (assistant.account if assistant.respond_to?(:account))
  end

  # Source-less Playground catalog preview. Runs ONLY for an explicit Playground run (source ==
  # 'playground' AND no conversation) — never the conversation-bound job paths (which own their own
  # product orchestration) and never an incidental source-less direct caller. It previews the SAME
  # deterministic product orchestration a real turn uses, so a valid catalog request is grounded in
  # the catalog instead of falling through to RAG as "unavailable". Fully read-only: no persistence,
  # delivery, or side effects. Returns nil (fall through to the unchanged RAG path) for a non-product
  # turn, a blank query, or any failure.
  #
  # Gate G applies here exactly as on the conversation path: an EXACT approved FAQ/KB match
  # (#faq_precedence?) short-circuits BEFORE the catalog preview, so an erroneous product
  # classification cannot preempt a curated approved answer in the Playground either — the turn
  # falls through to RAG, which returns the FAQ.
  def playground_preview(query, history)
    return nil unless source == PLAYGROUND_SOURCE && conversation.nil?
    return nil if query.blank?

    kb = knowledge_result(query)
    return nil if faq_precedence?(kb)

    account = product_account
    return nil if account.nil?

    Marine::Catalog::PlaygroundPreview.new(assistant: assistant, account: account)
                                      .call(query: query, history: history, state_token: state_token,
                                            knowledge_available: knowledge_available?(kb))
  end

  # Preserve the ephemeral product-flow state across a Playground turn that fell through to
  # RAG/FAQ/non-product. Those payloads carry no state_token, so the browser would clear the signed
  # flow (`data.state_token ?? null`) even though the real ProductFlowStateStore stays active across
  # such a turn (no mutation ran). Runs ONLY for an explicit Playground run (source == 'playground'
  # AND no conversation); every conversation-bound caller is untouched. The incoming token is
  # re-verified and the ORIGINAL signed string is echoed verbatim (no re-encode -> no TTL extension,
  # no raw flow accepted). A blank/tampered/expired/foreign token is never echoed (fail closed).
  def preserve_playground_state(payload)
    return payload unless source == PLAYGROUND_SOURCE && conversation.nil?
    return payload unless valid_playground_state_token?

    payload.merge('state_token' => state_token)
  end

  # True only when the client token verifies (signature/scope/expiry) and re-normalizes to a usable
  # in-memory flow — the same trust boundary PlaygroundPreview applies. Never accepts raw flow/raises.
  def valid_playground_state_token?
    return false if state_token.blank?

    account = product_account
    return false if account.nil?

    decoded = Marine::Catalog::PlaygroundStateToken.new(account: account, assistant: assistant).decode(state_token)
    Marine::Catalog::ProductFlowStateStore.new(conversation: nil).normalize_snapshot(decoded).present?
  rescue StandardError
    false
  end

  def response_generator
    @response_generator ||= Marine::Charge::ResponseGenerator.new(
      assistant: assistant,
      conversation: conversation,
      source: source
    )
  end

  def select_scenario(query)
    return nil if query.blank?

    scenario = Marine::Agent::ScenarioSelector.new(assistant: assistant).select(query)
    if scenario
      log_event('scenario.selected', scenario_id: scenario.id)
    else
      log_event('scenario.none')
    end
    scenario
  end

  # Custom HTTP tools have been removed to eliminate all direct outbound
  # connectivity between Marine AI and ERP, so no tool slugs are ever resolved.
  def resolved_tool_slugs(_scenario) = []

  def enrich(payload, scenario, tool_slugs)
    payload.merge(
      'orchestration_path' => orchestration_path(payload, scenario),
      'marine_scenario_id' => scenario&.id,
      'marine_scenario_title' => scenario&.title,
      'marine_scenario_tools' => tool_slugs
    )
  end

  def orchestration_path(payload, scenario)
    return PATH_HANDOFF if handoff?(payload)

    scenario ? PATH_SCENARIO_RETRIEVAL : PATH_RETRIEVAL
  end

  def handoff?(payload)
    payload['action'] == 'handoff' || payload['response'] == 'conversation_handoff'
  end

  def resolve_query(additional_message, message_history)
    additional_message.presence || extract_last_user_message(message_history)
  end

  def extract_last_user_message(message_history)
    message = Array(message_history).reverse.find do |item|
      item[:role].to_s == 'user' || item['role'].to_s == 'user'
    end
    message&.dig(:content) || message&.dig('content')
  end

  def handle_error(error)
    log_event('runner.error', error_class: error.class.name)
    capture(error)
    Marine::Circuit::HandoffService
      .low_confidence_payload(reason: RUNNER_ERROR_REASON)
      .merge('orchestration_path' => PATH_HANDOFF)
  end

  def capture(error)
    account = conversation&.account || (assistant.account if assistant.respond_to?(:account))
    return if account.nil?

    ChatwootExceptionTracker.new(error, account: account).capture_exception
  end

  def log_result(payload)
    if handoff?(payload)
      log_event('answer.handoff', path: payload['orchestration_path'], reason: payload['action_reason'])
    else
      log_event('answer.reply', path: payload['orchestration_path'],
                                confidence: payload['confidence'], source_type: payload['source_type'])
    end
  end

  # Structured, secret-free single-line logging. Only ids, slugs, confidence,
  # language, and reason codes are ever emitted — never auth config or API keys.
  def log_event(event, **fields)
    parts = fields.compact.map { |key, value| "#{key}=#{value}" }.join(' ')
    Rails.logger.info("#{LOG_PREFIX} event=#{event} #{parts}".strip)
  end

  def assistant_id
    assistant.id if assistant.respond_to?(:id)
  end

  def conversation_id
    conversation.id if conversation.respond_to?(:id)
  end

  # Never log a raw Message (its content is customer data); emit a safe id label.
  def source_label
    return "message:#{source.id}" if source.is_a?(::Message)

    source
  end
end
# rubocop:enable Metrics/ClassLength
