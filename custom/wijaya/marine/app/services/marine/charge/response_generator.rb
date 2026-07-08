class Marine::Charge::ResponseGenerator
  def initialize(assistant:, conversation: nil, source: nil)
    @assistant = assistant
    @conversation = conversation
    @source = source
  end

  def generate(additional_message: nil, message_history: [])
    query = additional_message.presence || extract_last_user_message(message_history)
    response = Marine::Cell::KnowledgeBaseService.new(assistant: assistant).best_match(query)
    return Marine::Circuit::HandoffService.low_confidence_payload(reason: 'no_confident_cell_match') if response.blank?

    {
      'response' => response.answer,
      'action' => 'reply',
      'agent_name' => assistant.name,
      'marine_cell_response_id' => response.id
    }
  end

  private

  attr_reader :assistant, :conversation, :source

  def extract_last_user_message(message_history)
    message = message_history.reverse.find do |item|
      item[:role].to_s == 'user' || item['role'].to_s == 'user'
    end
    message&.dig(:content) || message&.dig('content')
  end
end
