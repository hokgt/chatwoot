class Marine::Charge::ResponseGenerator
  DEFAULT_LANGUAGE = 'en'.freeze

  # RAG grounding budget: at most RAG_MAX_ENTRIES Knowledge Base entries, each
  # answer truncated to RAG_ENTRY_TRUNCATE chars, keep the system prompt bounded.
  RAG_MAX_ENTRIES = 20
  RAG_ENTRY_TRUNCATE = 500
  RAG_INSTRUCTION = 'Answer ONLY using the information in the Knowledge Base Context above. ' \
                    'If the answer is not found in the context, say you do not have that information ' \
                    'and offer to connect the customer with a human agent. ' \
                    'Never invent or fabricate information.'.freeze

  def initialize(assistant:, conversation: nil, source: nil)
    @assistant = assistant
    @conversation = conversation
    @source = source
  end

  def generate(additional_message: nil, message_history: [])
    customer_query = additional_message.presence || extract_last_user_message(message_history)
    query_translation = translate_query(customer_query)
    retrieval_query = query_translation[:text].presence || customer_query.to_s

    result = knowledge_base.retrieve(retrieval_query, limit: 1)

    if result.fallback_reason.present?
      llm_payload = llm_fallback_payload(customer_query, message_history, result.fallback_reason, query_translation)
      return llm_payload if llm_payload

      return handoff_payload(result.fallback_reason, query_translation, nil)
    end

    if result.confidence < 1.0
      rag_payload = rag_synthesis_payload(customer_query, message_history, result, query_translation)
      return rag_payload if rag_payload
    end

    response_translation = translate_response(result.answer, query_translation[:source_language])
    final_answer = response_translation[:text].presence || result.answer

    {
      'response' => final_answer,
      'action' => 'reply',
      'agent_name' => assistant.name,
      'marine_cell_response_id' => result.matched_response_id
    }.merge(metadata(result)).merge(translation_metadata(query_translation, response_translation))
  end

  private

  attr_reader :assistant, :conversation, :source

  def knowledge_base
    @knowledge_base ||= Marine::Cell::KnowledgeBaseService.new(assistant: assistant)
  end

  def metadata(result)
    {
      'confidence' => result.confidence,
      'citations' => result.citations,
      'source_type' => result.source_type,
      'response_ids' => result.response_ids,
      'document_ids' => result.document_ids,
      'fallback_reason' => result.fallback_reason
    }
  end

  def translate_query(query)
    Marine::Llm::TranslateQueryService.new(
      text: query,
      target_language: knowledge_language,
      account: llm_account
    ).call
  end

  def translate_response(answer, customer_language)
    Marine::Llm::TranslateResponseService.new(
      text: answer,
      target_language: customer_language,
      source_language: knowledge_language,
      account: llm_account
    ).call
  end

  # Only the answer text is translated; commit 2 confidence/citation metadata is
  # never passed through the translator. Keys stay stable across replies/handoffs.
  def translation_metadata(query_translation, response_translation)
    {
      'detected_language' => query_translation[:source_language],
      'query_language' => query_translation[:source_language],
      'response_language' => response_translation ? response_translation[:target_language] : query_translation[:source_language],
      'translated_query' => query_translation[:translated] ? query_translation[:text] : nil,
      'translation_applied' => query_translation[:translated],
      'translation_error' => query_translation[:error] || response_translation&.dig(:error),
      'response_translation_applied' => response_translation ? response_translation[:translated] : false
    }
  end

  # When retrieval finds no confident FAQ match, answer with Retrieval-Augmented
  # Generation: ground the LLM in ALL approved Knowledge Base content and forbid it
  # from inventing facts. This prevents the ungrounded hallucinations (e.g. fabricated
  # office addresses) that a persona-only prompt produced. Returns nil when the LLM is
  # unconfigured or fails so the caller falls through to handoff.
  def llm_fallback_payload(customer_query, message_history, fallback_reason, query_translation)
    service = Marine::Llm::BaseService.new(account: llm_account)
    return nil unless service.configured?

    result = service.chat(
      messages: messages_with_query(message_history, customer_query),
      system: rag_system_prompt
    )
    return nil unless result[:ok] && result[:message].present?

    {
      'response' => greeting_context.normalize_opening_greeting(result[:message]),
      'action' => 'reply',
      'agent_name' => assistant.name,
      'source_type' => 'llm_rag',
      'fallback_reason' => fallback_reason,
      'confidence' => 0.0,
      'citations' => [],
      'response_ids' => [],
      'document_ids' => []
    }.merge(translation_metadata(query_translation, nil))
  end

  # A non-exact retrieval match (confidence < 1.0) means the top FAQ answer may not
  # actually address the customer's question (e.g. "Apa itu Textilindo?" matching an
  # unrelated "Apa itu MOQ" FAQ on shared tokens). Instead of returning that raw
  # answer, synthesize a grounded reply from ALL approved Knowledge Base content plus
  # the customer question. Exact matches (confidence 1.0) skip this fast path. Returns
  # nil when the LLM is unconfigured or fails so the caller returns the raw FAQ answer.
  def rag_synthesis_payload(customer_query, message_history, result, query_translation)
    service = Marine::Llm::BaseService.new(account: llm_account)
    return nil unless service.configured?

    llm_result = service.chat(
      messages: messages_with_query(message_history, customer_query),
      system: rag_system_prompt
    )
    return nil unless llm_result[:ok] && llm_result[:message].present?

    {
      'response' => greeting_context.normalize_opening_greeting(llm_result[:message]),
      'action' => 'reply',
      'agent_name' => assistant.name,
      'source_type' => 'llm_rag',
      'fallback_reason' => nil,
      'confidence' => result.confidence,
      'citations' => result.citations,
      'response_ids' => result.response_ids,
      'document_ids' => result.document_ids
    }.merge(translation_metadata(query_translation, nil))
  end

  def rag_system_prompt
    sections = [assistant.config.to_h['instructions'].to_s.strip.presence, greeting_context.system_prompt]

    guardrails = Array(assistant.try(:guardrails)).map(&:to_s).map(&:strip).reject(&:blank?)
    sections << "Guardrails:\n#{guardrails.map { |g| "- #{g}" }.join("\n")}" if guardrails.any?

    guidelines = Array(assistant.try(:response_guidelines)).map(&:to_s).map(&:strip).reject(&:blank?)
    sections << "Response Guidelines:\n#{guidelines.map { |g| "- #{g}" }.join("\n")}" if guidelines.any?

    context = knowledge_base_context
    sections << "Knowledge Base Context:\n#{context}" if context.present?
    sections << RAG_INSTRUCTION

    sections.compact.join("\n\n").presence
  end

  # Marine-battery service owning the authoritative business-time grounding block and
  # the opening-greeting normalization safety net (see Marine::Charge::GreetingContext).
  def greeting_context = @greeting_context ||= Marine::Charge::GreetingContext.new(account: llm_account)

  # Builds the grounding block from every approved FAQ entry and document-backed
  # response. Each answer is truncated and the entry count is capped so the prompt
  # stays within the model context window.
  def knowledge_base_context
    entries = knowledge_base_entries
    return nil if entries.empty?

    entries.filter_map do |entry|
      question = entry.question.to_s.strip
      answer = entry.answer.to_s.strip
      next if answer.blank?

      "Q: #{question}\nA: #{answer.truncate(RAG_ENTRY_TRUNCATE)}"
    end.join("\n\n").presence
  end

  def knowledge_base_entries
    return [] unless assistant.respond_to?(:responses)

    approved = assistant.responses.approved
    # Prioritize document-backed responses (richer content, e.g. the Contact page
    # with address/phone/email) then fill remaining slots with FAQ entries so the
    # default scope's low-ID FAQs don't crowd documents out of the RAG context.
    docs = approved.where.not(documentable_type: nil).limit(RAG_MAX_ENTRIES / 2).to_a
    faqs = approved.where(documentable_type: nil).limit(RAG_MAX_ENTRIES - docs.size).to_a
    docs + faqs
  rescue StandardError => e
    Rails.logger.warn("Marine::Charge::ResponseGenerator RAG context failed: #{e.message}")
    []
  end

  def messages_with_query(message_history, customer_query)
    history = Array(message_history)
    last = history.last
    last_content = last && (last[:content] || last['content'])
    return history if last_content.to_s == customer_query.to_s

    history + [{ role: 'user', content: customer_query.to_s }]
  end

  def handoff_payload(reason, query_translation, response_translation)
    Marine::Circuit::HandoffService
      .low_confidence_payload(reason: reason)
      .merge(translation_metadata(query_translation, response_translation))
  end

  def knowledge_language
    lang = assistant.respond_to?(:config) ? assistant.config.to_h['language'] : nil
    lang.to_s.strip.presence || DEFAULT_LANGUAGE
  end

  def llm_account
    return conversation.account if conversation.respond_to?(:account) && conversation.account.present?

    assistant.account if assistant.respond_to?(:account)
  end

  def extract_last_user_message(message_history)
    message = message_history.reverse.find do |item|
      item[:role].to_s == 'user' || item['role'].to_s == 'user'
    end
    message&.dig(:content) || message&.dig('content')
  end
end
