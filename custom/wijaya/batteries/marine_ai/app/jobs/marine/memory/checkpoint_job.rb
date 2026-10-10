# frozen_string_literal: true

# Daily quiet-period backstop. Resolved conversations are intentionally excluded:
# their immediate transition hook owns final memory generation.
class Marine::Memory::CheckpointJob < ApplicationJob
  queue_as :low

  def perform
    MarineInbox.includes(:marine_assistant, :inbox).find_each do |link|
      assistant = link.marine_assistant
      next if assistant.feature_memory.blank?

      link.inbox.conversations.where(status: %i[open pending]).find_each do |conversation|
        checkpoint(assistant, conversation)
      end
    end
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
  end

  private

  def checkpoint(assistant, conversation)
    service = Marine::Memory::ContactNotesService.new(assistant: assistant, conversation: conversation)
    return unless service.checkpoint_eligible?

    service.generate_and_store(state: 'checkpoint')
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: conversation.account).capture_exception
  end
end
