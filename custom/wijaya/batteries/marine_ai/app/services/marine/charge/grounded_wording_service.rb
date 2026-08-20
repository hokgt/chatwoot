# Phase 5 — contextual wording for an approved-FAQ answer ONLY. Given the approved
# answer (the sole authoritative factual source), the latest customer request, the
# Phase 2 bounded history, and the Phase 4 opening/follow-up state, it asks the LLM to
# rephrase the approved answer contextually, applies the Phase 4 greeting enforcement,
# then delivers the result ONLY after a SEPARATE FactPreservationValidator call accepts
# the EXACT enforced candidate. Generation and validation are two distinct calls; the
# candidate is untrusted and never self-certified.
#
# Returns the accepted wording, or nil (a non-delivery signal) on ANY generation or
# validation failure or uncertainty. It never repairs, merges, or partially uses a
# rejected candidate, and falls closed silently without logging the approved answer,
# candidate, or customer text so the caller returns its existing exact fallback.
class Marine::Charge::GroundedWordingService
  # NUL and other unsafe C0/DEL control characters, excluding tab (\t), newline (\n),
  # and carriage return (\r) which are legitimate in prose.
  UNSAFE_CONTROL_CHARS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/

  GENERATION_INSTRUCTION = <<~PROMPT.strip
    Rephrase the Approved Answer below to reply to the customer in context.
    The Approved Answer is your ONLY source of facts. Preserve every material fact it states.
    Do not add, change, infer, or omit any factual claim, and introduce nothing the Approved Answer does not state.
    Answer the latest customer request directly, contextually, and concisely.
    Use earlier messages in this conversation only when they are relevant to the latest request.
    Output only your reply text, with no JSON, markdown, quotes, or explanation.
  PROMPT

  def initialize(account: nil)
    @account = account
  end

  def call(approved_answer:, customer_request:, message_history: [], opening: true)
    candidate = generate(approved_answer, customer_request, message_history, opening)
    return nil unless usable_generation?(candidate)

    # Phase 4 enforcement runs BEFORE validation so the validator judges the exact text
    # that would be delivered; a follow-up greeting-only reply enforces down to blank.
    enforced = greeting_context.enforce(candidate, opening: opening).presence
    return nil if enforced.blank?

    return nil unless validator.valid?(approved_answer: approved_answer, candidate: enforced)

    enforced
  rescue StandardError
    nil
  end

  private

  def generate(approved_answer, customer_request, message_history, opening)
    service = Marine::Llm::BaseService.new(account: @account)
    return nil unless service.configured?

    result = service.chat(
      messages: messages_with_query(message_history, customer_request),
      system: generation_prompt(approved_answer, opening)
    )
    return nil unless result[:ok] && result[:message].present?

    result[:message]
  end

  # Smallest generic output-shape gate: the generation is untrusted, so before greeting
  # enforcement or validation it must be a valid-encoding String with nonblank substantive
  # content, free of NUL/unsafe control characters, and not a machine-readable payload (a
  # whole fenced block, or a body whose entirety parses as a JSON object/array). Ordinary
  # prose that merely contains braces or punctuation is NOT rejected; nothing is repaired.
  def usable_generation?(text)
    return false unless text.is_a?(String) && text.valid_encoding?

    stripped = text.strip
    return false if stripped.blank?
    return false if text.match?(UNSAFE_CONTROL_CHARS)
    return false if stripped.start_with?('```')

    !whole_json_structure?(stripped)
  end

  def whole_json_structure?(stripped)
    return false unless ['{', '['].include?(stripped[0])

    parsed = JSON.parse(stripped)
    parsed.is_a?(Hash) || parsed.is_a?(Array)
  rescue JSON::ParserError
    false
  end

  def generation_prompt(approved_answer, opening)
    [GENERATION_INSTRUCTION, greeting_context.interaction_prompt(opening: opening), "Approved Answer:\n#{approved_answer}"].join("\n\n")
  end

  # Mirror the RAG path: append the latest request to the trigger-excluded history only
  # when it is not already the last message, so it reaches the LLM exactly once.
  def messages_with_query(message_history, customer_request)
    history = Array(message_history)
    last = history.last
    last_content = last && (last[:content] || last['content'])
    return history if last_content.to_s == customer_request.to_s

    history + [{ role: 'user', content: customer_request.to_s }]
  end

  def greeting_context = @greeting_context ||= Marine::Charge::GreetingContext.new(account: @account)

  def validator = @validator ||= Marine::Charge::FactPreservationValidator.new(account: @account)
end
