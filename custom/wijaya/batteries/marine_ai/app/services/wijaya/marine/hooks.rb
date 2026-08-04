module Wijaya::Marine::Hooks
  module_function

  # Consolidated claim used by MessageTemplates::HookExecutionService. Returns
  # true when Marine is handling this conversation — in which case the native
  # welcome/OOO/email-collect templates must be suppressed — and, when the
  # triggering message is a genuine inbound turn, schedules the Marine response.
  # Returns false (native templates run) for non-Marine inboxes.
  #
  # should_process_marine_response? already implies marine_handling_conversation?
  # (it is that predicate plus message.incoming?), so scheduling only fires for
  # inbound turns while suppression covers every message Marine is handling —
  # byte-for-byte with the previous four inline guards.
  def claim_message_templates!(conversation:, inbox:, message:)
    return false unless marine_handling_conversation?(conversation: conversation, inbox: inbox)

    after_message_template_trigger(conversation: conversation, inbox: inbox, message: message)
    true
  end

  def after_message_template_trigger(conversation:, inbox:, message:)
    return unless should_process_marine_response?(conversation, inbox, message)

    schedule_marine_response(conversation, message)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: conversation.account).capture_exception
  end

  # Linked Marine assistant id for an inbox, or nil when Marine is not linked.
  # Used by the core inbox serializer via the fail-open dispatcher.
  def inbox_marine_assistant_id(inbox:)
    return nil unless inbox.respond_to?(:marine_assistant)

    inbox.marine_assistant&.id
  end

  def after_conversation_resolved(conversation)
    inbox = conversation&.inbox
    return unless marine_memory_enabled?(conversation, inbox)

    ::Marine::Memory::GenerateContactNotesJob.perform_later(conversation)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: conversation&.account).capture_exception
  end

  def marine_memory_enabled?(conversation, inbox)
    return false if conversation.blank? || inbox.blank?

    assistant = inbox.respond_to?(:marine_assistant) ? inbox.marine_assistant : nil
    assistant.present? && assistant.respond_to?(:feature_memory) && assistant.feature_memory.present?
  end

  def marine_handling_conversation?(conversation:, inbox:)
    return false unless inbox.respond_to?(:marine_assistant) && inbox.marine_assistant.present?
    return false if conversation.resolved? || conversation.snoozed?

    # Marine handles the conversation until a human agent sends a reply.
    # We check for sender_type 'User' (human) — Marine's own replies use
    # sender_type 'Marine::Assistant' and must not block subsequent turns.
    conversation.messages.outgoing.where(private: false).where(sender_type: 'User').empty?
  end

  def should_process_marine_response?(conversation, inbox, message)
    return false unless message.incoming?
    return false unless inbox.respond_to?(:marine_assistant) && inbox.marine_assistant.present?
    return false if conversation.resolved? || conversation.snoozed?

    # Marine handles until a human agent replies.  WhatsApp conversations
    # are created as 'open' (not 'pending' like web widget), so we check
    # for human (User) outgoing messages instead of the conversation status.
    conversation.messages.outgoing.where(private: false).where(sender_type: 'User').empty?
  end

  def schedule_marine_response(conversation, message)
    job_args = [conversation, conversation.inbox.marine_assistant]
    if message.attachments.blank?
      ::Marine::Conversation::ResponseBuilderJob.perform_later(*job_args)
    else
      ::Marine::Conversation::ResponseBuilderJob.set(wait: 2.seconds).perform_later(*job_args)
    end
  end
end
