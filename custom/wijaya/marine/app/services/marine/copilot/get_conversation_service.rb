# Marine copilot single-conversation fetch. Resolves a conversation by its
# display id inside the user's permitted scope and returns citation metadata plus
# the conversation's LLM text. Returns nil when the conversation is not visible
# to the user (or belongs to another account).
class Marine::Copilot::GetConversationService < Marine::Copilot::SearchBaseService
  def perform(display_id:)
    return nil if display_id.blank?

    conversation = permissible_conversations.find_by(display_id: display_id)
    return nil if conversation.blank?

    conversation_citation(conversation).merge(
      summary: safe_llm_text(conversation)
    )
  end

  private

  def safe_llm_text(conversation)
    conversation.to_llm_text(include_contact_details: true).to_s.truncate(4000)
  rescue StandardError
    "Conversation ##{conversation.display_id}"
  end
end
