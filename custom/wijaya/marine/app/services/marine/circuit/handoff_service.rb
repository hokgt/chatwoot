class Marine::Circuit::HandoffService
  DEFAULT_MESSAGE = 'Transferring to another agent for further assistance.'.freeze

  def self.low_confidence_payload(reason:)
    {
      'response' => 'conversation_handoff',
      'action' => 'handoff',
      'action_source' => 'marine_circuit',
      'action_reason' => reason
    }
  end

  def initialize(conversation:, assistant:, reason: nil)
    @conversation = conversation
    @assistant = assistant
    @reason = reason
  end

  def perform
    return unless conversation_pending?

    create_private_reason_note if reason.present?
    create_handoff_message
    conversation.bot_handoff!
  end

  private

  attr_reader :conversation, :assistant, :reason

  def create_private_reason_note
    conversation.messages.create!(
      message_type: :outgoing,
      private: true,
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      sender: assistant,
      content: "Marine Circuit handoff: #{reason}"
    )
  end

  def create_handoff_message
    conversation.messages.create!(
      message_type: :outgoing,
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      sender: assistant,
      content: assistant.config['handoff_message'].presence || DEFAULT_MESSAGE
    )
  end

  def conversation_pending?
    status = Conversation.uncached { Conversation.where(id: conversation.id).pick(:status) }
    status == 'pending' || status == Conversation.statuses[:pending]
  end
end
