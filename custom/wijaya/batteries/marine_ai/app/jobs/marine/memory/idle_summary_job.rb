# frozen_string_literal: true

# Per-turn delayed idle trigger. It delegates all eligibility and persistence to the
# same service as the cron fallback; stale jobs safely no-op after newer activity.
class Marine::Memory::IdleSummaryJob < ApplicationJob
  queue_as :low

  def perform(conversation_id, assistant_id, _trigger_message_id = nil)
    conversation = Conversation.find_by(id: conversation_id)
    assistant = Marine::Assistant.find_by(id: assistant_id)
    return if conversation.nil? || assistant.nil?

    Marine::Memory::ContactNotesService.new(assistant: assistant, conversation: conversation)
                                       .generate_and_store(trigger_source: 'idle_timeout')
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: conversation&.account).capture_exception
  end
end
