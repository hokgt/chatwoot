class Marine::Conversation::ResponseBuilderJob < ApplicationJob
  queue_as :default

  def perform(conversation, assistant)
    @conversation = conversation
    @assistant = assistant
    return unless conversation_pending?

    Current.executed_by = assistant
    @response = Marine::Llm::AssistantChatService.new(assistant: assistant, conversation: conversation).generate_response(message_history: collect_previous_messages)
    process_response
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: conversation.account).capture_exception
    process_handoff('charge_error') if conversation_pending?
  ensure
    Current.executed_by = nil
  end

  private

  def collect_previous_messages
    @conversation.messages.where(message_type: [:incoming, :outgoing]).where(private: false).map do |message|
      { role: message.incoming? ? 'user' : 'assistant', content: message.content.to_s }
    end
  end

  def process_response
    if @response['action'] == 'handoff' || @response['response'] == 'conversation_handoff'
      process_handoff(@response['action_reason'])
    elsif conversation_pending?
      create_marine_reply
      @conversation.account.increment_marine_response_usage if @conversation.account.respond_to?(:increment_marine_response_usage)
    end
  end

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

  def process_handoff(reason = nil)
    Marine::Circuit::HandoffService.new(conversation: @conversation, assistant: @assistant, reason: reason).perform
  end

  def conversation_pending?
    status = Conversation.uncached { Conversation.where(id: @conversation.id).pick(:status) }
    status == 'pending' || status == Conversation.statuses[:pending]
  end
end
