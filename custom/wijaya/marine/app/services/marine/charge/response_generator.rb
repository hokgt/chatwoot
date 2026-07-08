class Marine::Charge::ResponseGenerator
  def initialize(assistant:, conversation: nil, source: nil)
    @assistant = assistant
    @conversation = conversation
    @source = source
  end

  def generate(additional_message: nil, message_history: [])
    query = additional_message.presence || extract_last_user_message(message_history)
    result = Marine::Cell::KnowledgeBaseService.new(assistant: assistant).retrieve(query, limit: 1)

    if result.fallback_reason.present?
      return Marine::Circuit::HandoffService.low_confidence_payload(reason: result.fallback_reason)
    end

    {
      'response' => result.answer,
      'action' => 'reply',
      'agent_name' => assistant.name,
      'marine_cell_response_id' => result.matched_response_id
    }.merge(metadata(result))
  end

  private

  attr_reader :assistant, :conversation, :source

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

  def extract_last_user_message(message_history)
    message = message_history.reverse.find do |item|
      item[:role].to_s == 'user' || item['role'].to_s == 'user'
    end
    message&.dig(:content) || message&.dig('content')
  end
end
