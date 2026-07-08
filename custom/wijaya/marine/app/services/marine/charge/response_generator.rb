class Marine::Charge::ResponseGenerator
  DEFAULT_LANGUAGE = 'en'.freeze

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
      return handoff_payload(result.fallback_reason, query_translation, nil)
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
