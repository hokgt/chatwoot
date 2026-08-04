class Marine::Llm::AssistantChatService
  def initialize(assistant:, conversation: nil, source: nil)
    @assistant = assistant
    @conversation = conversation
    @source = source
  end

  # `role:` is accepted for signature parity with Captain::Llm::AssistantChatService#generate_response;
  # the Marine agent runner derives role from message_history, so it is not forwarded here.
  def generate_response(additional_message: nil, message_history: [], role: 'user') # rubocop:disable Lint/UnusedMethodArgument
    Marine::Agent::Runner.new(
      assistant: @assistant,
      conversation: @conversation,
      source: @source
    ).run(additional_message: additional_message, message_history: message_history)
  end
end
