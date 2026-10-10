# frozen_string_literal: true

# Immediate/final trigger for a resolved Marine conversation. The job rechecks
# linkage, feature flag and resolved state, then delegates to the same incremental,
# race-safe private-note writer used by the daily checkpoint backstop.
class Marine::Memory::GenerateContactNotesJob < ApplicationJob
  queue_as :low

  def perform(conversation)
    assistant = enabled_assistant(conversation)
    return if assistant.blank?

    Marine::Memory::ContactNotesService.new(assistant: assistant, conversation: conversation)
                                       .generate_and_store(state: 'final')
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: conversation&.account).capture_exception
  end

  private

  def enabled_assistant(conversation)
    return unless conversation&.resolved?

    assistant = conversation.inbox&.try(:marine_assistant)
    assistant if assistant&.feature_memory.present?
  end
end
