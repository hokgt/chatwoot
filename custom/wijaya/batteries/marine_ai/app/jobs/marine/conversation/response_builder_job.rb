# Phase 5 — Automatic Response Integration and deterministic text replies.
#
# perform(conversation, assistant, trigger_message_id = nil):
#   * trigger_message_id nil  -> LEGACY 2-arg behavior, byte-for-byte, for jobs that
#     were already enqueued before Phase 5. It never starts the dynamic product flow
#     (which requires an incoming-message identity) and keeps the prior RAG path.
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

  # --- Legacy (2-arg) path — unchanged from before Phase 5 --------------------

  def legacy_perform
    return unless conversation_pending?

    Current.executed_by = @assistant
    @response = Marine::Llm::AssistantChatService.new(assistant: @assistant,
                                                      conversation: @conversation).generate_response(message_history: collect_previous_messages)
    process_response
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: @conversation.account).capture_exception
    process_handoff('charge_error') if conversation_pending?
  ensure
    Current.executed_by = nil
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
    @response = Marine::Llm::AssistantChatService.new(assistant: @assistant, conversation: @conversation,
                                                      source: message).generate_response(message_history: collect_previous_messages)
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
    apply_product_state(plan[:state])

    case plan[:action]
    when :handoff
      process_handoff(product_handoff_reason(plan))
    when :send_catalog
      deliver_product_catalog(plan)
      increment_marine_usage
    else
      create_product_reply(plan)
      increment_marine_usage
    end
    complete_claim
  end

  # Phase 6 — Native Product Catalog attachment delivery for a send_catalog action.
  # Runs INSIDE finalize's Conversation row lock + transaction, AFTER apply_product_state
  # has persisted the validated family, so selection reads the freshest flow. When exactly
  # one usable primary catalog exists for the validated family AND this flow has not
  # already sent a catalog, deliver ONE native attachment (reusing the existing blob) and
  # mark catalog_sent/document/message ONLY after the Message is created; otherwise fall
  # back to the identical deterministic clarify-variant TEXT so the customer can still
  # continue with an exact code. A create failure raises, rolling the whole finalization
  # back (no markers, no completed claim), leaving the job retryable.
  def deliver_product_catalog(plan)
    flow = current_product_flow
    document = catalog_selection(flow['validated_family'])

    if document && !catalog_already_sent?(flow)
      deliver_catalog_message(plan, document)
    elsif direct_catalog_request?(plan)
      create_product_message(direct_catalog_fallback_text(plan, flow, document))
    else
      create_product_reply(plan)
    end
  end

  def deliver_catalog_message(plan, document)
    message = Marine::Conversation::ProductMessageDeliveryService.new(
      conversation: @conversation, assistant: @assistant,
      document: document, content: localized_product_text(product_reply_text(plan))
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
  # beyond the approved display fields the presenter already bounded.
  def create_product_reply(plan)
    create_product_message(product_reply_text(plan))
  end

  def create_product_message(content)
    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      sender: @assistant,
      content: localized_product_text(content),
      additional_attributes: { source_type: 'marine_product', orchestration_path: 'product' }
    )
  end

  # Rewrites a deterministic English product reply into the latest customer's language
  # (attachment caption or plain product text alike). Localization is delivery-only: it
  # never changes the selected family/document or one-catalog-per-flow markers, and it
  # degrades to the original English on unknown/unconfigured/failed translation.
  def localized_product_text(content)
    # No trigger message (legacy path) means no customer-language signal to follow, so
    # deliver the deterministic English unchanged — the safe default.
    return content if @trigger_message.nil?

    Marine::Catalog::ReplyLocalizer.new(
      text: content,
      trigger_text: @trigger_message.content.to_s,
      context: customer_language_context,
      account: @conversation.account
    ).call
  end

  # Bounded recent customer turns, newest first — a fallback language signal only used
  # when the trigger message itself is too short/unknown to classify.
  def customer_language_context
    @conversation.messages.incoming.where(private: false).order(id: :desc).limit(MAX_LANGUAGE_CONTEXT).pluck(:content)
  end

  def process_handoff(reason = nil)
    Marine::Circuit::HandoffService.new(conversation: @conversation, assistant: @assistant, reason: reason).perform
  end

  # --- Deterministic product text --------------------------------------------

  # Fixed, fact-safe templates for descriptor kinds that carry no interpolated field.
  STATIC_PRODUCT_TEXT = {
    price_unavailable: "I'm sorry, I don't have the price for that item right now.",
    stock_available: 'Good news — that item is currently in stock.',
    stock_empty: "I'm sorry, that item is currently out of stock."
  }.freeze

  GENERIC_PRODUCT_TEXT = 'Could you share a little more detail about the product you need?'.freeze

  # Renders the caption/text for a plan. A DIRECT catalog request carries a :catalog reply
  # descriptor and renders a catalog caption; a catalog-ASSISTED send_catalog (reply nil)
  # renders the deterministic variant clarification, used both as its no-usable-catalog text
  # fallback and as the caption accompanying the native catalog attachment (Phase 6) so the
  # customer can continue with an exact code; every other product reply maps its frozen
  # descriptor kind to a fixed or field-interpolated, fact-safe template.
  def product_reply_text(plan)
    descriptor = plan[:reply] || {}
    dynamic = dynamic_product_text(descriptor)
    return dynamic if dynamic
    return clarify_variant_text(Array(plan.dig(:state, :changes, 'expected_attributes'))) if plan[:action] == :send_catalog

    STATIC_PRODUCT_TEXT[descriptor[:kind]] || GENERIC_PRODUCT_TEXT
  end

  def dynamic_product_text(descriptor)
    case descriptor[:kind]
    when :parent_info then parent_info_text(descriptor)
    when :variant_info then "Here are the details for #{descriptor[:variant_code]}. Would you like the price or availability?"
    when :price_available then price_available_text(descriptor)
    when :clarify_family then clarify_family_text(descriptor[:candidates])
    when :clarify_variant then clarify_variant_text(descriptor[:attribute_names])
    when :catalog then catalog_ready_text(descriptor)
    end
  end

  # True when the plan carries a DIRECT catalog descriptor (Phase 4 #plan_catalog), as
  # opposed to a catalog-assisted variant clarification (reply nil). Only a direct request
  # gets a catalog caption and a no-catalog fallback that never asks for a variant.
  def direct_catalog_request?(plan)
    plan.dig(:reply, :kind) == :catalog
  end

  def catalog_ready_text(descriptor)
    "Here is the product catalog for #{catalog_family_name(descriptor)}."
  end

  # No usable catalog for a DIRECT request: never ask for a variant (there is nothing to
  # disambiguate). If one was already sent this flow, say so; otherwise state none is
  # available. Both are deterministic and reference only the row-derived family name.
  def direct_catalog_fallback_text(plan, flow, document)
    name = catalog_family_name(plan[:reply] || {})
    if document && catalog_already_sent?(flow)
      "I've already shared the #{name} catalog with you above."
    else
      "I'm sorry, I don't have a catalog available for #{name} right now."
    end
  end

  def catalog_family_name(descriptor)
    descriptor[:family_name].presence || descriptor[:family_code] || 'that product'
  end

  def parent_info_text(descriptor)
    name = descriptor[:family_name].presence || descriptor[:family_code]
    "You're asking about #{name}. Which specific variant would you like to know about?"
  end

  def price_available_text(descriptor)
    amount = [descriptor[:currency], descriptor[:price_list_rate]].compact.join(' ')
    text = "The price is #{amount}"
    text += " per #{descriptor[:uom]}" if descriptor[:uom].present?
    "#{text}."
  end

  def clarify_family_text(candidates)
    names = Array(candidates).filter_map { |candidate| candidate[:name].presence || candidate[:code] }
    return 'Could you tell me which product you are interested in?' if names.empty?

    "Could you let me know which product you mean? For example: #{names.join(', ')}."
  end

  def clarify_variant_text(attribute_names)
    names = Array(attribute_names).reject(&:blank?)
    return 'Could you specify which variant you are interested in?' if names.empty?

    "Could you specify the #{names.join(', ')} you need?"
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
