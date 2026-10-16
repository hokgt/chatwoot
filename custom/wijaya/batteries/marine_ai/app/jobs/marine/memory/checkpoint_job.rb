# frozen_string_literal: true

# Daily fail-safe for delayed idle jobs. It uses the same eligibility/writer service;
# status is an eligibility input only and never a summary trigger.
class Marine::Memory::CheckpointJob < ApplicationJob
  queue_as :low

  def perform
    MarineInbox.includes(:marine_assistant, :inbox).find_each do |link|
      checkpoint_link(link)
    end
  end

  private

  def checkpoint_link(link)
    assistant = link.marine_assistant
    inbox = link.inbox
    return if assistant.blank? || inbox.blank? || assistant.feature_memory.blank?

    inbox.conversations.where(status: %i[open pending resolved]).find_each do |conversation|
      checkpoint(assistant, conversation)
    end
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
  end

  def checkpoint(assistant, conversation)
    Marine::Memory::ContactNotesService.new(assistant: assistant, conversation: conversation)
                                       .generate_and_store(trigger_source: 'cron_fallback')
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: conversation.account).capture_exception
  end
end
