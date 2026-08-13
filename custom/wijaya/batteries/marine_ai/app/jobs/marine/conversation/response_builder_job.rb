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
#     window. Catalog-needed becomes deterministic TEXT clarification; native
#     attachment delivery is Phase 6.
# rubocop:disable Metrics/ClassLength -- Phase 5 concentrates the trigger-bound
# orchestration the blueprint assigns to this job (claim, eligibility, finalization
# safety, state apply, action handling, and the small deterministic product-text
# templates) into one place; splitting it out would add an unwired helper file
# rather than integrate through the existing job as required.
class Marine::Conversation::ResponseBuilderJob < ApplicationJob
  queue_as :default

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

    if plan[:action] == :handoff
      process_handoff(product_handoff_reason(plan))
    else
      create_product_reply(plan)
      increment_marine_usage
    end
    complete_claim
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
    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      sender: @assistant,
      content: product_reply_text(plan),
      additional_attributes: { source_type: 'marine_product', orchestration_path: 'product' }
    )
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

  # send_catalog in Phase 5 is a text-only variant clarification (NO attachment /
  # document selection); every other product reply maps its frozen descriptor kind to
  # a fixed or field-interpolated, fact-safe template.
  def product_reply_text(plan)
    return clarify_variant_text(Array(plan.dig(:state, :changes, 'expected_attributes'))) if plan[:action] == :send_catalog

    descriptor = plan[:reply] || {}
    dynamic_product_text(descriptor) || STATIC_PRODUCT_TEXT[descriptor[:kind]] || GENERIC_PRODUCT_TEXT
  end

  def dynamic_product_text(descriptor)
    case descriptor[:kind]
    when :parent_info then parent_info_text(descriptor)
    when :variant_info then "Here are the details for #{descriptor[:variant_code]}. Would you like the price or availability?"
    when :price_available then price_available_text(descriptor)
    when :clarify_family then clarify_family_text(descriptor[:candidates])
    when :clarify_variant then clarify_variant_text(descriptor[:attribute_names])
    end
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
