# Phase 5 — Automatic Response Integration and deterministic text replies.
#
# perform(conversation, assistant, trigger_message_id = nil):
#   * trigger_message_id nil  -> LEGACY 2-arg compatibility path, for jobs that
#     were already enqueued before Phase 5. It now derives canonical bounded context
#     from the latest public incoming message and passes the current trigger separately,
#     while still not starting the dynamic product flow (it has no bound source).
#   * trigger_message_id set   -> TRIGGER-BOUND flow bound to that exact incoming
#     Message: claim BEFORE reasoning (per-message idempotency + duplicate-output
#     prevention), pre-reasoning eligibility, product orchestration BEFORE general
#     RAG (via AssistantChatService source:), then a FINAL finalization gate
#     (reload + eligibility recheck + newer-relevant-incoming stale check) before any
#     output. Product state is applied only through ProductFlowStateStore, and only
#     when finally eligible. The claim is completed only AFTER a successful outgoing
#     text / terminal no-output decision — never before delivery — so a mid-flight
#     failure leaves it retryable/stale rather than crashing a complete-before-deliver
#     window. Phase 6: a catalog-needed (send_catalog) turn delivers ONE native Product
#     Catalog attachment (reusing the existing document blob) when a single usable
#     primary catalog exists for the validated family and none has been sent this flow —
#     marking catalog_sent/document/message only after the Message is created — and
#     otherwise falls back to the identical deterministic clarify-variant TEXT.
# rubocop:disable Metrics/ClassLength -- Phase 5 concentrates the trigger-bound
# orchestration the blueprint assigns to this job (claim, eligibility, finalization
# safety, state apply, action handling, and the small deterministic product-text
# templates) into one place; splitting it out would add an unwired helper file
# rather than integrate through the existing job as required.
class Marine::Conversation::ResponseBuilderJob < ApplicationJob
  queue_as :default

  # Bounded recent customer turns consulted for language detection when the trigger
  # message alone is too short/unknown to classify.
  MAX_LANGUAGE_CONTEXT = 5

  def perform(conversation, assistant, trigger_message_id = nil)
    @conversation = conversation
    @assistant = assistant
    @trigger_message_id = trigger_message_id

    trigger_message_id.nil? ? legacy_perform : trigger_bound_perform
  end

  private

  # --- Legacy (2-arg) path — canonical bounded context, product flow disabled -----
  #
  # This path is used by jobs enqueued without a trigger-message id (pre-Phase-5, or any
  # source-less caller). It now grounds on the SAME canonical Phase 2 context as the
  # trigger-bound path: the latest eligible public incoming turn is the query trigger,
  # supplied SEPARATELY exactly once, and the bounded prior history (10 × 500 chars) is the
  # message history — replacing the former unbounded whole-conversation dump. The
  # AssistantChatService is still constructed with NO `source:`, so Agent::Runner derives no
  # canonical_context of its own and its product_payload stays disabled: Product Flow behavior
  # is unchanged on this path.

  def legacy_perform
    return unless conversation_pending?

    Current.executed_by = @assistant
    @response = generate_legacy_response
    process_response
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: @conversation.account).capture_exception
    process_handoff('charge_error') if conversation_pending?
  ensure
    Current.executed_by = nil
  end

  # Canonical legacy reasoning: bound the latest incoming turn as a separate trigger and pass
  # the bounded prior history alongside it. No `source:` is supplied (Product Flow stays off).
  def generate_legacy_response
    chat = Marine::Llm::AssistantChatService.new(assistant: @assistant, conversation: @conversation)
    trigger = legacy_trigger_message
    # No eligible incoming turn (impossible for a pending conversation, kept only for
    # compatibility): fall back to the prior unbounded whole-conversation history so behavior
    # degrades no worse than before rather than inventing a new response rule.
    return chat.generate_response(message_history: collect_previous_messages) if trigger.nil?

    context = Marine::Conversation::ContextBuilder.new(conversation: @conversation, trigger_message: trigger).build
    chat.generate_response(additional_message: context.trigger, message_history: context.history)
  end

  # The latest public incoming turn, chosen deterministically by (created_at, id) — the same
  # ordering key ContextBuilder uses. This gives identity to the "last user message" the old
  # source-less Runner picked from the flattened history, so the bounded trigger is resolved
  # exactly once instead of being buried inside an unbounded history.
  def legacy_trigger_message
    @conversation.messages.incoming.where(private: false).reorder(created_at: :desc, id: :desc).first
  end

  def process_response
    if handoff_response?
      process_handoff(@response['action_reason'])
    elsif conversation_pending?
      create_marine_reply
      increment_marine_usage
    end
  end

  # --- Trigger-bound (3-arg) product/RAG path --------------------------------

  def trigger_bound_perform
    message = trigger_message
    return unless message # not found / not incoming: stop safely, no claim, no output

    @trigger_message = message # primary language signal for product-reply localization
    @claim = Marine::Conversation::ProcessingClaim.new(message: message)
    acquired = @claim.acquire!
    return unless acquired.owner? # duplicate / completed / competing fresh claim: no second output

    @claim_id = acquired.claim['claim_id']
    return complete_no_output unless eligible? # takeover/resolved/snoozed BEFORE reasoning

    Current.executed_by = @assistant
    # No message_history is passed: the trigger-bound Agent::Runner derives the canonical
    # prior history and separately bounded current trigger from the Conversation + this exact
    # incoming Message (source:), so product-intent and RAG ground on the same context and the
    # trigger is supplied exactly once.
    @response = Marine::Llm::AssistantChatService.new(assistant: @assistant, conversation: @conversation,
                                                      source: message).generate_response
    # Phase 6 — precompute the deterministic localized fallback and (only if it survives BOTH
    # the deterministic protected-fact checker and the semantic validator) a natural-wording
    # candidate for eligible product replies, OUTSIDE the finalize row lock. Finalize still
    # rechecks eligibility/staleness and applies state/message/claim atomically.
    prepare_product_wording
    prepare_handoff_wording
    finalize
  rescue StandardError => e
    # A failure anywhere in reasoning/finalization (including message-create) must
    # leave the claim untouched ('processing') so it is retryable/stale. Never
    # complete it and never emit a fallback here — that would risk a duplicate or a
    # complete-before-deliver crash window.
    ChatwootExceptionTracker.new(e, account: @conversation.account).capture_exception
  ensure
    Current.executed_by = nil
  end

  # Final gate under the freshest DB view, inside the Conversation row lock and its
  # transaction: a takeover DURING reasoning, or a newer relevant incoming message
  # (this job is now stale), stops all output. Only past this gate is any state
  # applied or message created, and everything the gate opens — product-flow state,
  # the outgoing text (or handoff), usage, and claim completion — runs as ONE atomic
  # unit. If any step raises, the whole finalization rolls back (no partial state, no
  # partial handoff, no completed claim) and the exception leaves the claim
  # 'processing' so the job is retryable. eligibility and staleness are rechecked here
  # against the freshest DB state the lock guarantees. `next` (not `return`) exits the
  # block so the transaction commits on the terminal-no-output branch rather than
  # rolling back the claim completion it just recorded.
  def finalize
    # reload first so lock! sees a clean record (a caller may hand us an in-memory
    # Conversation with unpersisted attribute changes, which lock! refuses); with_lock
    # then reloads again under the row lock to give the gate the freshest DB state.
    @conversation.reload
    @conversation.with_lock do
      next complete_no_output unless eligible?
      next complete_no_output if newer_relevant_incoming?

      if product_response?
        finalize_product
      elsif handoff_response?
        process_handoff(@response['action_reason'])
        complete_claim
      else
        create_marine_reply
        increment_marine_usage
        complete_claim
      end
    end
  end

  # Product decision, all within the finalize transaction: apply the deterministic
  # state operation, then produce output (deterministic text or handoff) plus usage,
  # and complete the claim last. Because the whole method runs inside finalize's lock
  # and transaction, a failure in any later step rolls the state operation back too,
  # so a retry replays from a clean slate rather than re-mutating an already-bumped
  # flow.
  def finalize_product
    plan = @response['product_plan']
    # Bounded delivery-language the extractor read from the same customer turn; the
    # localizer prefers it over local (CLD3) detection. Never influences selection.
    @product_language = plan[:language]
    apply_product_state(plan[:state])

    # A pure stock reply whose localized coded text could not be PROVEN in the customer's language
    # (and whose natural candidate was not accepted) routes through the SAME circuit handoff as an
    # ordinary product handoff — never a wrong-language stock assertion. It carries the precomputed
    # in-language acknowledgement only when that too is provably in the customer's language; when the
    # acknowledgement itself cannot be proven in-language it hands off SILENTLY (internal transfer,
    # no visible message) so no wrong-language line is ever sent.
    if @force_stock_language_handoff
      process_handoff(product_handoff_reason(plan), message: @handoff_message, silent: @stock_handoff_silent)
    else
      case plan[:action]
      when :handoff
        process_handoff(product_handoff_reason(plan), message: @handoff_message)
      when :send_catalog
        deliver_product_catalog(plan)
        increment_marine_usage
      else
        create_product_reply(plan)
        increment_marine_usage
      end
    end
    complete_claim
  end

  # Phase 6/7 — Native Product Catalog attachment delivery for a send_catalog action.
  # Runs INSIDE finalize's Conversation row lock + transaction, AFTER apply_product_state
  # has persisted the validated family, so selection reads the freshest flow. When exactly
  # one usable primary catalog exists for the validated family AND this flow has not
  # already sent a catalog, deliver ONE native attachment (reusing the existing blob) and
  # mark catalog_sent/document/message ONLY after the Message is created; otherwise fall
  # back to a deterministic direct no-catalog/already-sent line or a catalog-assisted variant
  # clarification. The customer-facing TEXT is the lock-free precomputed localized/naturalized
  # caption/fallback when its outcome+document signature still matches, else deterministic English
  # (#catalog_content) — so NO localization/network call is made under the lock. A create failure
  # raises, rolling the whole finalization back (no markers, no completed claim), leaving the job
  # retryable.
  def deliver_product_catalog(plan)
    flow = current_product_flow
    document = catalog_selection(flow['validated_family'])
    outcome = catalog_outcome(plan, flow, document)
    content = catalog_content(outcome, plan, flow, document)

    if outcome == CATALOG_DELIVER
      deliver_catalog_message(document, content)
    else
      create_product_message_with(content)
    end
  end

  # The delivered catalog text: the precomputed localized/naturalized text ONLY when the rechecked
  # outcome and selected document still match the lock-free snapshot's signature; otherwise the
  # exact deterministic English fallback, computed WITHOUT any network/translation call under the
  # finalize row lock (a signature mismatch means a race — deliver safely, never re-localize here).
  def catalog_content(outcome, plan, flow, document)
    prepared = @catalog_wording
    return prepared[:text] if prepared && prepared[:signature] == catalog_signature(outcome, document)

    deterministic_catalog_text(outcome, plan, flow, document)
  end

  def deliver_catalog_message(document, content)
    message = Marine::Conversation::ProductMessageDeliveryService.new(
      conversation: @conversation, assistant: @assistant,
      document: document, content: content
    ).call
    mark_catalog_sent(document, message)
  end

  # One catalog per flow: record the delivery markers only after the Message exists, as a
  # version-bumping flow update within the same finalize transaction.
  def mark_catalog_sent(document, message)
    Marine::Catalog::ProductFlowStateStore.new(conversation: @conversation).update!(
      'catalog_sent' => true,
      'catalog_document_id' => document.id,
      'catalog_message_id' => message.id
    )
  end

  def catalog_selection(family_code)
    Marine::Documents::ProductCatalogSelector.new(
      account: @conversation.account, assistant: @assistant, family_code: family_code
    ).call
  end

  def current_product_flow
    Marine::Catalog::ProductFlowStateStore.new(conversation: @conversation).current || {}
  end

  def catalog_already_sent?(flow)
    flow['catalog_sent'] == true
  end

  # The four deterministic send_catalog outcomes, shared by the lock-free precompute and the
  # under-lock delivery so the outcome (and its signature) is computed identically in both.
  CATALOG_DELIVER = :deliver
  CATALOG_ASSISTED_FALLBACK = :assisted_fallback
  CATALOG_ALREADY_SENT = :already_sent
  CATALOG_NO_CATALOG = :no_catalog

  # Classify a send_catalog turn from (plan, current flow, selected document): deliver the native
  # catalog when one exists and none has been sent this flow; otherwise a DIRECT request splits
  # into already-sent vs no-catalog, and a catalog-ASSISTED turn falls back to a variant
  # clarification. Pure over the given inputs — no side effect, no network.
  def catalog_outcome(plan, flow, document)
    return CATALOG_DELIVER if document && !catalog_already_sent?(flow)
    return CATALOG_ASSISTED_FALLBACK unless presenter.direct_catalog_request?(plan)

    document ? CATALOG_ALREADY_SENT : CATALOG_NO_CATALOG
  end

  # Outcome + selected-document identity: the minimal signature that decides both the branch and
  # the deterministic text. A lock-free/under-lock mismatch means the delivery context changed
  # (a race), so the precomputed localized text is discarded in favor of deterministic English.
  def catalog_signature(outcome, document)
    [outcome, document&.id]
  end

  # The exact deterministic ENGLISH text for an outcome — no localization/network. The caption
  # (deliver / assisted fallback) is the plan's deterministic product text; the direct no-catalog
  # and already-sent lines come from the row-derived family name only.
  def deterministic_catalog_text(outcome, plan, flow, document)
    case outcome
    when CATALOG_DELIVER, CATALOG_ASSISTED_FALLBACK then presenter.reply_text(plan)
    else presenter.direct_catalog_fallback_text(plan[:reply] || {}, already_sent: document && catalog_already_sent?(flow))
    end
  end

  # The flow the under-lock selection will read, predicted lock-free: apply_product_state runs a
  # :start (a fresh flow, clearing catalog markers) or an :update (preserving them) BEFORE
  # selection, so a :start is simulated as an empty flow and the validated family is taken from
  # the plan's own state change (falling back to the current flow's family when unchanged). Only
  # the family and catalog_sent marker matter to #catalog_outcome.
  def predicted_catalog_flow(plan)
    changes = plan.dig(:state, :changes) || {}
    base = plan.dig(:state, :operation) == :start ? {} : current_product_flow
    base.merge('validated_family' => changes['validated_family'] || base['validated_family'])
  end

  def apply_product_state(state)
    store = Marine::Catalog::ProductFlowStateStore.new(conversation: @conversation)
    case state[:operation]
    when :start then store.start!(state[:changes])
    when :update then store.update!(state[:changes])
    end
  end

  # --- Message builders ------------------------------------------------------

  def create_marine_reply
    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      sender: @assistant,
      content: @response['response'],
      additional_attributes: {
        agent_name: @response['agent_name'],
        marine_cell_response_id: @response['marine_cell_response_id'],
        confidence: @response['confidence'],
        citations: @response['citations'],
        source_type: @response['source_type'],
        response_ids: @response['response_ids'],
        document_ids: @response['document_ids'],
        fallback_reason: @response['fallback_reason'],
        marine_scenario_id: @response['marine_scenario_id'],
        orchestration_path: @response['orchestration_path']
      }.compact
    )
  end

  # Deterministic product TEXT only — no citations, confidence, or raw catalog facts
  # beyond the approved display fields the presenter already bounded. When Phase 6 committed
  # this eligible reply to lock-free delivery (@product_wording_prepared), deliver the prepared
  # text verbatim — it is an accepted natural-wording candidate or its exact deterministic
  # localized fallback, already localized and validated, so it is NOT localized/transformed
  # again and no LLM/translation call is made under the finalize lock. The explicit flag (not
  # text truthiness) gates this so an eligible path never re-enters the localization path.
  # Ineligible product replies retain the existing deterministic localization path.
  def create_product_reply(plan)
    return create_product_message_with(@prepared_product_text) if @product_wording_prepared

    create_product_message(presenter.reply_text(plan))
  end

  def create_product_message(content)
    create_product_message_with(localized_product_text(content))
  end

  def create_product_message_with(final_text)
    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      sender: @assistant,
      content: final_text,
      additional_attributes: { source_type: 'marine_product', orchestration_path: 'product' }
    )
  end

  # --- Phase 6/7: fact-protected natural product wording (precomputed, lock-free) ---------
  #
  # Runs after Agent::Runner returns and BEFORE finalize acquires the Conversation row lock,
  # so no LLM/network call is made under the lock. It dispatches the two special product actions
  # to their own precompute paths (send_catalog -> #prepare_catalog_wording; handoff ->
  # #prepare_handoff_wording) and handles every other delivered product TEXT (parent/variant info,
  # family/variant clarification, stock and price-available outcomes, and the generic/excluded
  # replies) here: it ALWAYS computes and retains the exact deterministic localized fallback and
  # sets the explicit @product_wording_prepared flag, so finalize never localizes under its row
  # lock — even for a descriptor that is not naturalization-eligible. When the descriptor IS
  # protection-eligible, the fallback is replaced by an accepted natural candidate from
  # Marine::Catalog::GroundedProductWordingService, grounded ONLY on that localized fallback plus
  # the Phase 2 bounded canonical trigger/history and opening/follow-up state. A wording/context
  # failure keeps the localized fallback; an unexpected localization failure — before any localized
  # fallback exists — falls back to the deterministic English presenter.reply_text (the exact text
  # ReplyLocalizer itself degrades to) with NO further network call. Nothing is persisted here.
  def prepare_product_wording
    return unless product_response?
    return unless @trigger_message

    plan = @response['product_plan']
    # A send_catalog caption/fallback is precomputed by its own outcome-signature path; a product
    # handoff acknowledgement is precomputed by prepare_handoff_wording. Everything else is a
    # delivered product TEXT: precompute its exact localized fallback here (so finalize never
    # localizes under the row lock), naturalized only when the descriptor is protection-eligible.
    return prepare_catalog_wording(plan) if plan[:action] == :send_catalog
    return if plan[:action] == :handoff

    @product_language = plan[:language]
    @product_wording_prepared = true
    descriptor = plan[:reply]
    fallback = localized_product_text(presenter.reply_text(plan), action: plan[:action], descriptor: descriptor)
    @prepared_product_text = naturalized_product_text(plan, descriptor, fallback)
  rescue StandardError
    @prepared_product_text = degraded_product_text(plan)
  end

  # Preparation failed before a validated localized reply existed. Deliver the deterministic English
  # text — EXCEPT for a pure stock reply under a known non-source target, where English would be a
  # wrong-language stock assertion: the shared composer refuses it and hands off SILENTLY instead
  # (the strict per-language guarantee is preserved, and no wrong-language stock line is ever sent).
  # Unknown/source targets keep the English fallback (no guarantee is claimed there). No network
  # call is made here (localization already failed).
  def degraded_product_text(plan)
    english = presenter.reply_text(plan)
    return english unless stock_reply_kind?(plan[:reply])

    decision = stock_composer.degraded(text: english, reply_language: @product_language)
    return decision.text if decision.deliver?

    @force_stock_language_handoff = true
    @stock_handoff_silent = true
    nil
  end

  # An accepted natural-wording candidate when the descriptor is protection-eligible, else the exact
  # localized fallback. A pure stock reply is delegated to the shared
  # Marine::Catalog::StockReplyComposer (the SAME dynamic response boundary the source-less
  # PlaygroundPreview consumes) so both surfaces reach the identical DELIVER/HANDOFF business
  # conclusion; every other protection-eligible reply keeps the inline naturalize-or-fallback rule.
  # Runs inside #prepare_product_wording's rescue, so any wording/localization failure still degrades
  # to the deterministic English text.
  def naturalized_product_text(plan, descriptor, fallback)
    return stock_reply_text(descriptor, fallback) if stock_reply_kind?(descriptor)
    return fallback unless fact_protection.eligible?(action: plan[:action], descriptor: descriptor)

    wording_candidate(plan, descriptor, fallback) || fallback
  end

  # Resolve a pure stock reply through the shared composer, then map its Decision onto this
  # conversation's delivery adapter: deliver the accepted/in-language text, or record the fail-closed
  # circuit-handoff flags (visible in-language acknowledgement, or SILENT internal transfer). The
  # composer runs the natural wording and the strict fail-closed language check identically to the
  # Playground, so neither surface can claim availability while the other hands off.
  def stock_reply_text(descriptor, fallback)
    context = Marine::Conversation::ContextBuilder.new(conversation: @conversation, trigger_message: @trigger_message).build
    decision = stock_composer.compose(
      descriptor: descriptor, fallback: fallback, reply_language: @product_language,
      customer_request: context.trigger, message_history: context.history, opening: context.opening?,
      localized_ack: -> { localized_product_text(presenter.handoff_ack_text(nil)) }
    )
    return decision.text if decision.deliver?

    @force_stock_language_handoff = true
    @handoff_message = decision.message
    @stock_handoff_silent = decision.silent
    nil
  end

  # Pure binary-availability reply kinds — the ONLY replies whose visible text carries the strict
  # "always in the customer's language" guarantee (their sole fact is a variant code, so the safe
  # floor can drop to a factless in-language handoff without losing a price/quantity/other fact).
  STOCK_REPLY_KINDS = Marine::Catalog::StockReplyComposer::STOCK_KINDS

  def stock_reply_kind?(descriptor)
    descriptor.is_a?(Hash) && STOCK_REPLY_KINDS.include?(descriptor[:kind])
  end

  def stock_composer
    @stock_composer ||= Marine::Catalog::StockReplyComposer.new(account: @conversation.account)
  end

  # --- Phase 7: catalog caption / fallback wording (precomputed, lock-free) --------------
  #
  # A send_catalog turn produces one of four deterministic outcomes under the finalize lock:
  # deliver the native catalog with a caption, an already-sent/no-catalog direct fallback, or a
  # catalog-assisted variant clarification. Predicting the outcome from the SAME signals finalize
  # will read (the post-state validated family + the selected document), this precomputes — OUTSIDE
  # the lock — the localized text for that ONE predicted outcome (a DIRECT catalog caption is
  # additionally naturalized through the fact-protected wording path), plus an outcome+document
  # SIGNATURE. Under the lock, finalize uses the precomputed text ONLY when the rechecked outcome
  # and document still match the signature; on any mismatch (a race — e.g. a catalog sent
  # meanwhile) it uses the exact deterministic English fallback with NO network call. At most ONE
  # predicted outcome is prepared, so no speculative multi-call fan-out ever runs — here or under
  # the lock. A preparation failure leaves no snapshot, so finalize falls back to deterministic
  # English.
  def prepare_catalog_wording(plan)
    @product_language = plan[:language]
    flow = predicted_catalog_flow(plan)
    document = catalog_selection(flow['validated_family'])
    outcome = catalog_outcome(plan, flow, document)
    @catalog_wording = { signature: catalog_signature(outcome, document),
                         text: prepared_catalog_text(outcome, plan, flow, document) }
  rescue StandardError
    @catalog_wording = nil
  end

  # The localized (and, for a DIRECT catalog caption, naturalized) text for the predicted outcome.
  def prepared_catalog_text(outcome, plan, flow, document)
    english = deterministic_catalog_text(outcome, plan, flow, document)
    return catalog_caption_text(plan, english) if outcome == CATALOG_DELIVER

    localized_product_text(english)
  end

  # The delivered catalog caption: the localized deterministic caption, and — for a DIRECT catalog
  # request (a protection-eligible :catalog descriptor) — a natural same-language rephrase grounded
  # only on that localized caption plus Phase 2 bounded context. A catalog-ASSISTED caption (reply
  # nil) carries no naturalizable descriptor, so it stays the localized deterministic clarification.
  def catalog_caption_text(plan, english)
    descriptor = plan[:reply]
    fallback = localized_product_text(english, action: plan[:action], descriptor: descriptor)
    return fallback unless presenter.direct_catalog_request?(plan)

    wording_candidate(plan, descriptor, fallback) || fallback
  end

  # Natural-wording candidate grounded ONLY on the already-computed localized fallback plus the
  # Phase 2 bounded canonical trigger/history and opening/follow-up state. A wording/context
  # failure returns nil so the caller retains the localized fallback — never re-localizing and
  # never calling the network again.
  def wording_candidate(plan, descriptor, fallback)
    context = Marine::Conversation::ContextBuilder.new(conversation: @conversation, trigger_message: @trigger_message).build
    Marine::Catalog::GroundedProductWordingService.new(account: @conversation.account).call(
      action: plan[:action], descriptor: descriptor, fallback: fallback,
      customer_request: context.trigger, message_history: context.history, opening: context.opening?,
      reply_language: @product_language
    )
  rescue StandardError
    nil
  end

  def fact_protection
    @fact_protection ||= Marine::Catalog::ProductFactProtectionValidator.new
  end

  # --- Phase 7: context-aware natural product-handoff acknowledgement (precomputed, lock-free) ---
  #
  # A product-flow handoff (an unsupported request — warehouse location, delivery to a
  # customer-supplied destination, shipping cost — or an exact-quantity question) must not post
  # the generic, company-branded default handoff line. Runs AFTER Agent::Runner returns and
  # BEFORE finalize acquires the row lock (no LLM/network call under the lock), only for a
  # product handoff. It computes a deterministic, factless, already-localized acknowledgement and
  # (only if it survives every gate) a natural same-language rephrase grounded ONLY on that
  # acknowledgement plus the Phase 2 bounded canonical trigger/history and opening/follow-up
  # state. The result is the per-turn public handoff message passed to HandoffService; a
  # wording/context failure keeps the localized acknowledgement, and an unexpected failure keeps
  # the plain factless English acknowledgement (never the branded default). Non-product handoffs
  # (RAG/legacy/runner) leave @handoff_message nil and are unaffected. Asserts no fact, so it can
  # acknowledge a customer-supplied destination without turning it into a delivery/cost claim.
  def prepare_handoff_wording
    return unless product_response?
    return unless @trigger_message
    return unless @response['product_plan'][:action] == :handoff

    @product_language = @response['product_plan'][:language]
    ack = presenter.handoff_ack_text(@response['product_plan'][:handoff_category])
    fallback = localized_product_text(ack)
    @handoff_message = handoff_wording_candidate(fallback) || fallback
  rescue StandardError
    @handoff_message = Marine::Catalog::ReplyPresenter::HANDOFF_ACK_TEXT
  end

  # Natural handoff acknowledgement grounded ONLY on the already-localized factless
  # acknowledgement plus the Phase 2 bounded canonical trigger/history and opening/follow-up
  # state. Any wording/context failure returns nil so the caller keeps the localized fallback.
  def handoff_wording_candidate(fallback)
    context = Marine::Conversation::ContextBuilder.new(conversation: @conversation, trigger_message: @trigger_message).build
    Marine::Catalog::GroundedHandoffWordingService.new(account: @conversation.account).call(
      fallback: fallback, customer_request: context.trigger,
      message_history: context.history, opening: context.opening?
    )
  rescue StandardError
    nil
  end

  # Rewrites a deterministic English product reply into the latest customer's language
  # (attachment caption or plain product text alike). It prefers the bounded language the
  # intent extractor read from the same turn (@product_language) and only falls back to
  # local CLD3 detection when that is missing/malformed. Localization is delivery-only: it
  # never changes the selected family/document or one-catalog-per-flow markers, and it
  # degrades to the original English on unknown/unconfigured/failed translation.
  # action/descriptor are the OPTIONAL protected product descriptor and its action: when supplied,
  # the localizer additionally keeps the descriptor's protected display values literal in any
  # translation. A factless text (handoff acknowledgement, direct no-catalog line) supplies neither
  # and relies on the localizer's generic token-inventory + semantic factual-safety gates.
  def localized_product_text(content, action: nil, descriptor: nil)
    # No trigger message (legacy path) means no customer-language signal to follow, so
    # deliver the deterministic English unchanged — the safe default.
    return content if @trigger_message.nil?

    Marine::Catalog::ReplyLocalizer.new(
      text: content,
      trigger_text: @trigger_message.content.to_s,
      context: customer_language_context,
      provider_language: @product_language,
      fallback_language: configured_reply_language,
      account: @conversation.account,
      action: action,
      descriptor: descriptor
    ).call
  end

  # The assistant's configured operating (KB/reply) language, used by the localizer as the
  # deterministic customer-language fallback when the per-turn LLM provider language is absent —
  # so a CLD3 misclassification of a short customer turn can never override the known operating
  # language and deliver a wrong-language product reply. nil when unconfigured (CLD3 fallback
  # preserved). Mirrors ResponseGenerator#knowledge_language's config read; the localizer
  # normalizes/validates the value.
  def configured_reply_language
    @assistant.config.to_h['language'] if @assistant.respond_to?(:config)
  end

  # Bounded recent customer turns, newest first — a fallback language signal only used
  # when the trigger message itself is too short/unknown to classify.
  def customer_language_context
    @conversation.messages.incoming.where(private: false).order(id: :desc).limit(MAX_LANGUAGE_CONTEXT).pluck(:content)
  end

  def process_handoff(reason = nil, message: nil, silent: false)
    Marine::Circuit::HandoffService.new(conversation: @conversation, assistant: @assistant,
                                        reason: reason, message: message, silent: silent).perform
  end

  # --- Deterministic product text --------------------------------------------

  # Shared, pure presenter for the deterministic English product text. Extracted so the
  # trigger-bound job and the source-less Marine::Catalog::PlaygroundPreview render the exact
  # same wording from one source of truth (no drift, no duplicated business text).
  def presenter
    @presenter ||= Marine::Catalog::ReplyPresenter.new
  end

  # Safe, allowlisted-symbol-derived reason for the private handoff note.
  def product_handoff_reason(plan)
    "product_#{plan.dig(:reply, :kind) || 'handoff'}"
  end

  # --- Claim / eligibility / staleness ---------------------------------------

  def trigger_message
    message = @conversation.messages.find_by(id: @trigger_message_id)
    message if message&.incoming?
  end

  def eligible?
    Marine::Conversation::Eligibility.new(conversation: @conversation).decision.eligible?
  end

  # A public incoming message newer than the trigger means the customer has moved on;
  # this job is stale and must not answer the superseded turn.
  def newer_relevant_incoming?
    @conversation.messages.incoming.where(private: false).exists?(['id > ?', @trigger_message_id])
  end

  def complete_claim
    @claim.complete!(claim_id: @claim_id)
  end

  # Terminal no-output branch: record completion so a duplicate delivery of the same
  # incoming message never reprocesses, then stop.
  def complete_no_output
    complete_claim
    nil
  end

  def increment_marine_usage
    @conversation.account.increment_marine_response_usage if @conversation.account.respond_to?(:increment_marine_response_usage)
  end

  # --- Shared helpers --------------------------------------------------------

  # Unbounded whole-conversation history. Retained ONLY as the legacy no-trigger fallback
  # (see #generate_legacy_response) — an impossible case for a pending conversation, where
  # there is no incoming turn to bound. Normal legacy execution uses the canonical bounded
  # ContextBuilder context instead, so this is never the standard policy.
  def collect_previous_messages
    @conversation.messages.where(message_type: [:incoming, :outgoing]).where(private: false).map do |message|
      { role: message.incoming? ? 'user' : 'assistant', content: message.content.to_s }
    end
  end

  def product_response?
    @response.is_a?(Hash) && @response['product_plan'].present?
  end

  def handoff_response?
    @response['action'] == 'handoff' || @response['response'] == 'conversation_handoff'
  end

  def conversation_pending?
    # Marine should respond if the conversation is still eligible — not resolved
    # or snoozed, and no human agent (sender_type 'User') has sent an outgoing
    # message.  WhatsApp conversations are 'open' from the start, not 'pending'
    # like web widget, so we cannot rely on the status alone.
    status = Conversation.uncached { Conversation.where(id: @conversation.id).pick(:status) }
    return false if status == 'resolved' || status == 'snoozed'

    @conversation.messages.outgoing.where(private: false).where(sender_type: 'User').empty?
  end
end
# rubocop:enable Metrics/ClassLength
