class Marine::Llm::AssistantChatService
  def initialize(assistant:, conversation: nil, source: nil)
    @assistant = assistant
    @conversation = conversation
    @source = source
  end

  def generate_response(additional_message: nil, message_history: [], role: 'user')
    query = additional_message.presence || extract_last_user_message(message_history)
    response = Marine::AssistantResponse.search(query, account_id: @assistant.account_id).where(assistant_id: @assistant.id).first
    return handoff_response('no_confident_cell_match') if response.blank?

    { 'response' => response.answer, 'action' => 'reply', 'agent_name' => @assistant.name }
  end

  private

  def extract_last_user_message(message_history)
    message_history.reverse.find { |message| message[:role].to_s == 'user' || message['role'].to_s == 'user' }&.dig(:content) ||
      message_history.reverse.find { |message| message[:role].to_s == 'user' || message['role'].to_s == 'user' }&.dig('content')
  end

  def handoff_response(reason)
    { 'response' => 'conversation_handoff', 'action' => 'handoff', 'action_source' => 'marine_circuit', 'action_reason' => reason }
  end
end
