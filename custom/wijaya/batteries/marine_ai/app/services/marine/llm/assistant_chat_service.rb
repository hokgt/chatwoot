class Marine::Llm::AssistantChatService
  # `state_token` is the opaque signed ephemeral product-flow state for the source-less Playground
  # preview (nil on every conversation-bound path). It is round-tripped through the browser and
  # verified server-side; it is never persisted.
  def initialize(assistant:, conversation: nil, source: nil, state_token: nil)
    @assistant = assistant
    @conversation = conversation
    @source = source
    @state_token = state_token
  end

  # `role:` is accepted for signature parity with Captain::Llm::AssistantChatService#generate_response;
  # the Marine agent runner derives role from message_history, so it is not forwarded here.
  def generate_response(additional_message: nil, message_history: [], role: 'user') # rubocop:disable Lint/UnusedMethodArgument
    Marine::Agent::Runner.new(
      assistant: @assistant,
      conversation: @conversation,
      source: @source,
      state_token: @state_token
    ).run(additional_message: additional_message, message_history: message_history)
  end
end
