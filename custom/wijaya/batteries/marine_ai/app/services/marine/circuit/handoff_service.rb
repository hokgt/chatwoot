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

  # message: an OPTIONAL per-turn public handoff line (e.g. a context-aware, language-consistent
  # acknowledgement of the current unsupported request). When blank, the configured/default
  # message is used unchanged, so every non-product handoff path is unaffected.
  def initialize(conversation:, assistant:, reason: nil, message: nil)
    @conversation = conversation
    @assistant = assistant
    @reason = reason
    @message = message
  end

  # Idempotent, concurrency-safe handoff. Under the Conversation row lock (reloaded to
  # the freshest DB state), an already-active handoff marker short-circuits: no new
  # public message, no new private note, no second bot_handoff!. The first handoff
  # atomically creates the private reason note (when applicable), the configured/default
  # public message, invokes bot_handoff!, and persists the active marker LAST — all in
  # one transaction, so any failure rolls back both the messages and the marker and the
  # exception propagates for retry. Nested with_lock (finalize already holds the row
  # lock) reduces to a savepoint + reentrant re-lock, matching the ProductFlowStateStore
  # mutation pattern this battery already uses.
  def perform
    conversation.with_lock do
      next if handoff_active?
      next unless conversation_pending?

      message_ids = []
      message_ids << create_private_reason_note.id if reason.present?
      message_ids << create_handoff_message.id
      conversation.bot_handoff!
      handoff_store.activate!(message_ids: message_ids)
    end
  end

  private

  attr_reader :conversation, :assistant, :reason, :message

  def handoff_store
    @handoff_store ||= Marine::Circuit::HandoffStateStore.new(conversation: conversation)
  end

  def handoff_active?
    handoff_store.active?
  end

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
      content: message.presence || assistant.config['handoff_message'].presence || DEFAULT_MESSAGE
    )
  end

  # Marine may hand off only while the conversation is still eligible. Delegate to the
  # centralized Eligibility contract for the resolved / snoozed / active-handoff and
  # human-takeover (a public User reply OR an external_echo the human sent from the
  # native app, e.g. WhatsApp, Instagram) safety checks. Hooks intentionally keeps its
  # own narrower scheduling/takeover behavior; this gate is not meant to match it.
  # Eligibility reads the HandoffStateStore but never calls back into this service, so
  # there is no recursion.
  def conversation_pending?
    Marine::Conversation::Eligibility.new(conversation: conversation).decision.eligible?
  end
end
