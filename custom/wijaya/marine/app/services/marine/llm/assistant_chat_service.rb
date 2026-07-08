class Marine::Llm::AssistantChatService
  def initialize(assistant:, conversation: nil, source: nil)
    @assistant = assistant
    @conversation = conversation
    @source = source
  end

  def generate_response(additional_message: nil, message_history: [], role: 'user')
    Marine::Charge::ResponseGenerator.new(
      assistant: @assistant,
      conversation: @conversation,
      source: @source
    ).generate(additional_message: additional_message, message_history: message_history)
  end
end
