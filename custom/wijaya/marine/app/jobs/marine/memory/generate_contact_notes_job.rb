# Enqueued when a conversation is resolved. Generates Marine memory contact notes,
# but only for conversations whose inbox is linked to a Marine assistant that has
# the feature_memory toggle enabled. Independent of unrelated AI config/gates.
#
# The job re-checks Marine linkage and the feature toggle itself (defence in depth,
# so it stays correct even if enqueued directly), is account-scoped, and is safe
# when records have been deleted between enqueue and execution.
class Marine::Memory::GenerateContactNotesJob < ApplicationJob
  queue_as :low

  def perform(conversation)
    return if conversation.blank?

    inbox = conversation.inbox
    assistant = inbox&.try(:marine_assistant)
    return if assistant.blank?
    return unless assistant.feature_memory.present?

    Marine::Memory::ContactNotesService.new(assistant: assistant, conversation: conversation).generate_and_store
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: conversation&.account).capture_exception
  end
end
